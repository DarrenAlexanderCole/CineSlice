"""Makes the four Core ML models that are DBS-TIGER-DnR's speech estimate (Tsinghua, Apache-2.0,
https://github.com/JusperLee/Dynamic-Band-Splitting) for one 6 s mono window, without its
STFT/ISTFT, into PocketInstrument/Media:

- TigerFront: spec (1, 2, 1025, 517), the window's STFT as [re, im] (n_fft 2048, hop 512, Hann,
  centred with reflect padding: torch.stft's defaults) -> tokens (1, 132, 128, 517) for the
  separator, its slot mask (1, 1, 128, 1), and what the back end needs: hard (1, 1025) band
  boundaries, tokenProbs and tokenMask (1, 128).
- TigerStepFirst / TigerStep: one of the separator's 8 passes (it reuses one block's weights);
  the later passes also take the front's tokens back in.
- TigerBack: the separator's output, the boundaries and the spec -> speechRe, speechIm
  (1, 1025, 517), the speech stem's spectrum. Everything else is the mixture minus the speech.

In one piece the network unrolls to ~18k operations, and an iPhone is killed loading it; in four,
the separator pass is compiled once and run 8 times.

The dynamic band splitting (hard Top-K boundaries, per-segment softmax pooling via scatter,
atan2, complex masks) is rewritten here with dense one-hot matrices and real arithmetic so Core ML
can run it; the script checks the rewrite against the original model and the Core ML chain
against the rewrite.

Usage: python export.py <Dynamic-Band-Splitting checkout> <mixture.wav> <output folder>
"""
import math, sys
import numpy as np, soundfile as sf, torch
import torch.nn.functional as F
from torch import nn

repo, wav_path, out_dir = sys.argv[1:4]
sys.path.insert(0, repo)
torch.backends.nnpack.set_flags(False)  # NNPACK's depthwise convolutions take minutes per window on Apple CPUs
from dbs.models import DBSTIGER
from dbs.models import tiger

SR, WIN, HOP = 44100, 2048, 512
L = 6 * SR
T = 1 + L // HOP
SPEECH = 2  # sources are music, sfx, speech


def atan2(y, x):
    tiny = torch.full_like(x, 1e-12)
    base = torch.atan(y / torch.where(x.abs() < 1e-12, tiny, x))
    return torch.where(x > 0, base,
                       torch.where(x < 0, torch.where(y >= 0, base + math.pi, base - math.pi),
                                   torch.sign(y) * (math.pi / 2)))


def physics_features(spec_ri):
    re, im = spec_ri[:, 0], spec_ri[:, 1]
    mag = torch.sqrt(re * re + im * im) + 1e-6
    mag_norm = F.normalize(mag - mag.mean(dim=-1, keepdim=True), dim=-1)
    term_time = 1.0 - (mag_norm[:, :-1] * mag_norm[:, 1:]).sum(dim=-1)
    # The wrapped phase step between neighbouring bins is the angle of z[k+1] * conj(z[k]).
    cr = re[:, 1:] * re[:, :-1] + im[:, 1:] * im[:, :-1]
    ci = im[:, 1:] * re[:, :-1] - re[:, 1:] * im[:, :-1]
    term_phase = atan2(ci, cr).std(dim=-1)
    mean = mag.mean(dim=-1)
    mag_pad = torch.cat([mean[:, :1], mean, mean[:, -1:]], dim=1)
    term_peak = torch.relu(2 * mag_pad[:, 1:-1] - mag_pad[:, :-2] - mag_pad[:, 2:])
    return term_time, term_phase, term_peak


def boundary_logits(chunker, spec_ri, router, similarity):
    term_time, term_phase, term_peak = physics_features(spec_ri)
    router_feat = router(spec_ri, use_energy=chunker.use_energy)
    energy = tiger._energy_features(spec_ri, chunker.energy_feature_mode) if chunker.use_energy else None
    residual = chunker.residual_scale * similarity(router_feat, chunker.band_id, energy)
    logits = (chunker.alpha * F.pad(term_time, (1, 0), value=1.0)
              + chunker.beta * F.pad(term_phase, (1, 0), value=1.0)
              + chunker.gamma * term_peak + residual + chunker.bias)
    return torch.cat([torch.full_like(logits[:, :1], 10.0), logits[:, 1:]], dim=1)


def topk_boundaries(logits, num_tokens):
    """Bin 0 plus the num_tokens - 1 most likely bins (ranked by logit: no ties where sigmoid saturates)."""
    rest = logits[:, 1:]
    internal = min(num_tokens - 1, rest.shape[1])
    # Each bin's rank as a count of the bins above it: the GPU's top-k only goes to k = 16.
    rank = (rest.unsqueeze(1) > rest.unsqueeze(2)).to(logits.dtype).sum(dim=2)
    return torch.cat([torch.ones_like(logits[:, :1]), (rank < internal).to(logits.dtype)], dim=1)


def one_hot(index, count):
    """index [B, F] (float) -> [B, F, count]."""
    return (index.unsqueeze(-1) == torch.arange(count, dtype=index.dtype).view(1, 1, count)).to(index.dtype)


def pool(chunker, features, probs, hard):
    """PhysicsChunker.pool, dense."""
    bsz, freq, dim, time = features.shape
    k = chunker.max_chunks
    is_b = hard
    seg = torch.clamp(torch.cumsum(is_b, dim=1) - 1, 0, k - 1)
    onehot = one_hot(seg, k)
    weights = (1.0 + torch.sigmoid(chunker.boundary_pool_gain) * is_b * probs
               + torch.sigmoid(chunker.interior_pool_gain) * (1.0 - is_b) * probs)
    scores = chunker.chunk_attn(features.mean(dim=-1)).squeeze(-1) + torch.log(weights.clamp(min=1e-6))
    # Softmax within each segment.
    seg_max = (scores.unsqueeze(-1) + (onehot - 1.0) * 1e4).amax(dim=1, keepdim=True)
    e = torch.exp(scores - (onehot * seg_max).sum(dim=-1))
    denom = torch.matmul(e.unsqueeze(1), onehot)
    w = e / (onehot * denom).sum(dim=-1).clamp(min=1e-8)
    weighted = (features * w.view(bsz, freq, 1, 1)).reshape(bsz, freq, dim * time)
    tokens = torch.matmul(onehot.transpose(1, 2), weighted).view(bsz, k, dim, time)

    counts = onehot.sum(dim=1)
    confidence = is_b * probs + (1.0 - is_b) * (1.0 - probs)
    conf_mean = (onehot * confidence.unsqueeze(-1)).sum(dim=1) / counts.clamp(min=1.0)
    positions = torch.arange(freq, dtype=probs.dtype).view(1, freq, 1)
    first = torch.where((onehot * is_b.unsqueeze(-1)) > 0, positions, torch.full_like(onehot, float(freq))).amin(dim=1)
    valid = (first < freq).to(probs.dtype)
    boundary_p = (probs.unsqueeze(-1) * (positions == first.unsqueeze(1)).to(probs.dtype)).sum(dim=1)
    token_probs = 0.5 * (boundary_p + conf_mean) * valid
    token_mask = (counts > 0).to(probs.dtype) * valid
    return tokens, token_probs, token_mask


def dechunk(dechunker, tokens, hard, token_probs, token_mask, spec_re, spec_im):
    """FreqDechunker.forward for the speech source only, dense and real-valued."""
    bsz, count, dim, time = tokens.shape
    freq = dechunker.band_width
    outs = [tokens[:, 0]]
    for i in range(1, count):
        p = token_probs[:, i].view(bsz, 1, 1)
        outs.append((p * tokens[:, i] + (1 - p) * outs[-1]) * token_mask[:, i].view(bsz, 1, 1))
    smoothed = torch.stack(outs, dim=1)
    seg = torch.clamp(torch.cumsum(hard, dim=1) - 1, 0, count - 1)
    z = torch.matmul(one_hot(seg, count), smoothed.reshape(bsz, count, dim * time)).view(bsz, freq, dim, time)
    z = z.permute(0, 2, 1, 3)
    for block in dechunker.freq_refine_blocks:
        z = block["norm"](z + block["pw"](block["act"](block["dw"](z))))
    z = z.permute(0, 2, 1, 3).reshape(bsz * freq, dim, time)
    # The original views this as (B, F, sources, 2, 2, T); Core ML stops at rank 5.
    n = dechunker.num_sources
    params = dechunker.mask_net(z).view(bsz * freq, n, 4, time)
    mask_real = params[:, :, 0] * torch.sigmoid(params[:, :, 1])
    mask_imag = params[:, :, 2] * torch.sigmoid(params[:, :, 3])
    mr = (mask_real[:, SPEECH] - (mask_real.sum(dim=1) - 1) / n).view(bsz, freq, time)
    mi = (mask_imag[:, SPEECH] - mask_imag.sum(dim=1) / n).view(bsz, freq, time)
    return spec_re * mr - spec_im * mi, spec_re * mi + spec_im * mr


def adaptive_avg_pool1d(x, size):
    """F.adaptive_avg_pool1d as a constant matrix (the lengths are fixed)."""
    length = int(x.shape[-1])
    if length == size:
        return x
    a = np.zeros((length, size), dtype=np.float32)
    for i in range(size):
        s, e = (i * length) // size, -(-((i + 1) * length) // size)
        a[s:e, i] = 1.0 / (e - s)
    return torch.matmul(x, torch.from_numpy(a).to(x.dtype))


def uconv_forward(self, x):
    residual = x
    out = [self.spp_dw[0](self.proj_1x1(x))]
    for k in range(1, self.depth):
        out.append(self.spp_dw[k](out[-1]))
    size = int(out[-1].shape[-1])
    global_f = sum(adaptive_avg_pool1d(f, size) for f in out)
    global_f = self.globalatt(global_f)
    fused = [self.loc_glo_fus[i](out[i], global_f) for i in range(self.depth)]
    expanded = None
    for i in range(self.depth - 2, -1, -1):
        expanded = self.last_layer[i](fused[i], fused[i - 1] if i == self.depth - 2 else expanded)
    return self.res_conv(expanded) + residual


def nearest(x, length):
    """F.interpolate(mode="nearest", size=length) as a constant gather."""
    source = int(x.shape[-1])
    index = torch.from_numpy(np.floor(np.arange(length) * (source / length)).astype(np.int64))
    return x.index_select(-1, index)


def injection_forward(self, x_l, x_g):
    length = int(x_l.shape[-1])
    gate = nearest(self.act(self.global_act(x_g)), length)
    return self.local_embedding(x_l) * gate + nearest(self.global_embedding(x_g), length)


def attention_forward(self, x):
    """MultiHeadSelfAttention2D for one item, heads regrouped with a plain reshape (the original
    goes through rank 5). The weights-times-values product is written transposed: as `attn @ v`
    the GPU compiler fails on it ("MLIR pass manager failed"), as `(v^T @ attn^T)^T` it runs."""
    if self.dim == 4:
        x = x.transpose(-2, -1)
    batch, _, time, freq = x.shape
    assert batch == 1
    residual = x
    q = torch.cat([layer(x) for layer in self.Queries], dim=0).transpose(1, 2).flatten(start_dim=2)
    k = torch.cat([layer(x) for layer in self.Keys], dim=0).transpose(1, 2).flatten(start_dim=2)
    v = torch.cat([layer(x) for layer in self.Values], dim=0).transpose(1, 2)
    v_shape = v.shape
    attn = F.softmax(torch.matmul(q, k.transpose(1, 2)) / (q.shape[-1] ** 0.5), dim=2)
    v = torch.matmul(v.flatten(start_dim=2).transpose(1, 2), attn.transpose(1, 2)).transpose(1, 2)
    v = v.reshape(v_shape).transpose(1, 2)
    x = self.attn_concat_proj(v.reshape(1, -1, time, freq)) + residual
    if self.dim == 4:
        x = x.transpose(-2, -1)
    return x


def split_lstm(lstm):
    """A one-layer bidirectional LSTM as two one-way ones with its weights (the second reads the
    sequence reversed): an iPhone (iOS 27) is killed loading a bidirectional Core ML LSTM."""
    ways = []
    for suffix in ("", "_reverse"):
        way = nn.LSTM(lstm.input_size, lstm.hidden_size, batch_first=True)
        for name in ("weight_ih", "weight_hh", "bias_ih", "bias_hh"):
            getattr(way, f"{name}_l0").data.copy_(getattr(lstm, f"{name}_l0{suffix}").data)
        ways.append(way.eval().requires_grad_(False))
    return ways


def router_forward(self, spec_ri, use_energy):
    batch, _, freq, _ = spec_ri.shape
    cnn = self.cnn_extractor(spec_ri)
    _, dim, _, time = cnn.shape
    x = cnn.permute(0, 2, 3, 1).reshape(batch * freq, time, dim)
    if use_energy:
        energy = tiger._energy_features(spec_ri, self.energy_feature_mode)
        energy = self.energy_proj(energy.reshape(batch * freq, 1, -1).expand(-1, time, -1))
    else:
        energy = x.new_zeros(batch * freq, time, self.energy_dim)
    x = torch.cat([x, energy], dim=-1)
    if not hasattr(self, "one_way"):
        self.one_way = split_lstm(self.lstm)
    _, (forward_h, _) = self.one_way[0](x)
    _, (backward_h, _) = self.one_way[1](torch.flip(x, dims=[1]))
    return torch.cat([forward_h[-1], backward_h[-1]], dim=-1).view(batch, freq, dim)


tiger.SharedChunkRouterBackbone.forward = router_forward
tiger.UConvBlock.forward = uconv_forward
tiger.InjectionMultiSum.forward = injection_forward
tiger.MultiHeadSelfAttention2D.forward = attention_forward


class Front(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, spec):
        m = self.m
        tokens, masks, hards, probs_out = [], [], [], []
        for (start, end), chunker in zip(m.band_slices, m.chunkers):
            sub = spec[:, :, start:end]
            logits = boundary_logits(chunker, sub, m.shared_router_backbone, m.shared_similarity_projection)
            hard = topk_boundaries(logits, chunker.num_tokens)
            features = chunker.encoder_proj(sub).permute(0, 2, 1, 3)
            x, token_probs, token_mask = pool(chunker, features, torch.sigmoid(logits), hard)
            tokens.append(x)
            masks.append(token_mask)
            hards.append(hard)
            probs_out.append(token_probs)
        mask = torch.cat(masks, dim=1)
        # Recurrent.forward's start: masked, then [B, C, bands, T].
        x = (torch.cat(tokens, dim=1) * mask.unsqueeze(-1).unsqueeze(-1)).permute(0, 2, 1, 3)
        return x, mask.view(1, 1, -1, 1), torch.cat(hards, dim=1), torch.cat(probs_out, dim=1), mask


class StepFirst(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.sep = m.separator

    def forward(self, x, mask):
        return self.sep._freq_time(x, 1, x.shape[2], x.shape[1], x.shape[3], mask)


class Step(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.sep = m.separator

    def forward(self, x, tokens, mask):
        inp = self.sep.concat_block(tokens + x)
        return self.sep._freq_time(inp, 1, x.shape[2], x.shape[1], x.shape[3], mask)


class Back(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, separated, hard, token_probs, token_mask, spec):
        m = self.m
        separated = separated.permute(0, 2, 1, 3)
        res, ims, offset = [], [], 0
        for (start, end), chunker, dechunker in zip(m.band_slices, m.chunkers, m.dechunkers):
            count = chunker.max_chunks
            re, im = dechunk(dechunker, separated[:, offset:offset + count], hard[:, start:end],
                             token_probs[:, offset:offset + count], token_mask[:, offset:offset + count],
                             spec[:, 0, start:end], spec[:, 1, start:end])
            res.append(re)
            ims.append(im)
            offset += count
        return torch.cat(res, dim=1), torch.cat(ims, dim=1)


model = DBSTIGER.from_pretrained("JusperLee/DBS-TIGER-DnR").eval().requires_grad_(False)
front, first, step, back = Front(model).eval(), StepFirst(model).eval(), Step(model).eval(), Back(model).eval()
PASSES = model.separator.iterations
window = torch.hann_window(WIN)

# A real 6 s window: the original model against the rewrite, as waveforms.
wav, sr = sf.read(wav_path, dtype="float32")
assert sr == SR
mono = torch.from_numpy(wav.mean(1) if wav.ndim == 2 else wav)
mono = F.pad(mono, (0, max(0, L - mono.shape[0])))[:L].view(1, L)


def snr(ref, x):
    return 10 * math.log10(float((ref ** 2).sum()) / float(((ref - x) ** 2).sum() + 1e-20))


def chain(run_front, run_first, run_step, run_back, spec):
    tokens, mask, hard, token_probs, token_mask = run_front(spec)
    x = run_first(tokens, mask)
    for _ in range(1, PASSES):
        x = run_step(x, tokens, mask)
    return run_back(x, hard, token_probs, token_mask, spec)


with torch.inference_mode():
    z = torch.stft(mono, WIN, HOP, window=window, return_complex=True)
    spec = torch.stack([z.real, z.imag], dim=1)
    re, im = chain(front, first, step, back, spec)
    mine = torch.istft(torch.complex(re, im), WIN, HOP, window=window, length=L)
    if "--skip-check" not in sys.argv:
        ref = model(mono.view(1, 1, L))[0, SPEECH].view(1, L)
        print("rewrite vs original speech SNR dB", round(snr(ref, mine), 1), flush=True)
    tokens, mask, hard, token_probs, token_mask = front(spec)
    x1 = first(tokens, mask)
    traced = {
        "TigerFront": torch.jit.trace(front, (spec,)),
        "TigerStepFirst": torch.jit.trace(first, (tokens, mask)),
        "TigerStep": torch.jit.trace(step, (x1, tokens, mask)),
        "TigerBack": torch.jit.trace(back, (x1, hard, token_probs, token_mask, spec)),
    }

import coremltools as ct
from coremltools.converters.mil.frontend.torch import ops as ct_ops
from coremltools.converters.mil import Builder as mb

# Traced shapes reach `int` as 1-element arrays, which coremltools 9 can't cast.
_cast = ct_ops._cast
def _cast_scalar(context, node, dtype, dtype_name):
    x = context[node.inputs[0]]
    if x.val is not None and np.size(x.val) == 1 and np.ndim(x.val) > 0:
        context.add(mb.const(val=dtype(np.asarray(x.val).reshape(-1)[0]), name=node.name))
        return
    _cast(context, node, dtype, dtype_name)
ct_ops._cast = _cast_scalar

# The separator's big activations pass between models as float16, so Swift hands one model's
# output straight to the next.
half = np.float16
grid = tuple(tokens.shape)
io = {
    "TigerFront": ([ct.TensorType(name="spec", shape=spec.shape)],
                   [ct.TensorType(name="tokens", dtype=half), ct.TensorType(name="mask"),
                    ct.TensorType(name="hard"), ct.TensorType(name="tokenProbs"), ct.TensorType(name="tokenMask")]),
    "TigerStepFirst": ([ct.TensorType(name="tokens", shape=grid, dtype=half), ct.TensorType(name="mask", shape=mask.shape)],
                       [ct.TensorType(name="x", dtype=half)]),
    "TigerStep": ([ct.TensorType(name="x", shape=grid, dtype=half), ct.TensorType(name="tokens", shape=grid, dtype=half),
                   ct.TensorType(name="mask", shape=mask.shape)],
                  [ct.TensorType(name="next", dtype=half)]),
    "TigerBack": ([ct.TensorType(name="separated", shape=grid, dtype=half), ct.TensorType(name="hard", shape=hard.shape),
                   ct.TensorType(name="tokenProbs", shape=token_probs.shape),
                   ct.TensorType(name="tokenMask", shape=token_mask.shape), ct.TensorType(name="spec", shape=spec.shape)],
                  [ct.TensorType(name="speechRe"), ct.TensorType(name="speechIm")]),
}
import os, time
paths = {}
for name, module in traced.items():
    inputs, outputs = io[name]
    mlmodel = ct.convert(module, inputs=inputs, outputs=outputs, minimum_deployment_target=ct.target.iOS17,
                         compute_precision=ct.precision.FLOAT16)
    mlmodel.short_description = f"DBS-TIGER-DnR (Tsinghua, Apache-2.0), {name}: see Tools/dbs_tiger/export.py"
    paths[name] = os.path.join(out_dir, name + ".mlpackage")
    mlmodel.save(paths[name])

loaded = {}
for name, path in paths.items():
    t = time.time()
    loaded[name] = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    print(f"{name} load {time.time() - t:.1f} s", flush=True)

ml_front = lambda spec: (lambda p: (p["tokens"], p["mask"], p["hard"], p["tokenProbs"], p["tokenMask"]))(
    loaded["TigerFront"].predict({"spec": spec}))
ml_first = lambda tokens, mask: loaded["TigerStepFirst"].predict({"tokens": tokens, "mask": mask})["x"]
ml_step = lambda x, tokens, mask: loaded["TigerStep"].predict({"x": x, "tokens": tokens, "mask": mask})["next"]
ml_back = lambda x, hard, tp, tm, spec: (lambda p: (p["speechRe"], p["speechIm"]))(loaded["TigerBack"].predict(
    {"separated": x, "hard": hard, "tokenProbs": tp, "tokenMask": tm, "spec": spec}))
chain(ml_front, ml_first, ml_step, ml_back, spec.numpy())
t = time.time()
re, im = chain(ml_front, ml_first, ml_step, ml_back, spec.numpy())
print("coreml chain %.2f s per window" % (time.time() - t), flush=True)
coreml = torch.istft(torch.complex(torch.from_numpy(re).float(), torch.from_numpy(im).float()),
                     WIN, HOP, window=window, length=L)
print("coreml vs rewrite speech SNR dB", round(snr(mine, coreml), 1), flush=True)
