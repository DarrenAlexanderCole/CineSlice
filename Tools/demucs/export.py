"""Makes PocketInstrument/Media/HTDemucs.mlpackage: HTDemucs's network (without its STFT/ISTFT) to Core ML, for one 7.8 s segment.

Inputs: mix (1, 2, L) waveform at 44.1 kHz; spec (1, 4, 2048, T) the mix's STFT as
[L.re, L.im, R.re, R.im] (demucs `_spec` + `_magnitude`). Outputs, each for voice and
for everything else (drums + bass + other): a spectrogram in the same layout, and a
waveform. A stem is ISTFT(spec) + wave.
"""
import sys, torch, numpy as np, coremltools as ct
import coremltools.optimize.coreml as cto
from demucs.pretrained import get_model
import demucs.transformer
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
# Eval-time "random" shifts are randrange(0 + 1) == 0; torch.export can't take the call.
demucs.transformer.random.randrange = lambda n: 0

# The fused attention kernel has no Core ML equivalent; the plain path converts.
torch.backends.mha.set_fastpath_enabled(False)
model = get_model("htdemucs").models[0].eval()
L = int(model.segment * model.samplerate)
T = -(-L // model.hop_length)
print("segment", L, "frames", T, model.sources)
V = model.sources.index("vocals")

class Net(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, mix, spec):
        m = self.m
        x = spec
        B, C, Fq, Tn = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.bottom_channels:
            b, c, f, t = x.shape
            x = x.reshape(b, c, f * t)
            x = m.channel_upsampler(x)
            x = x.reshape(b, -1, f, t)
            xt = m.channel_upsampler_t(xt)
        x, xt = m.crosstransformer(x, xt)
        if m.bottom_channels:
            b, c, f, t = x.shape
            x = x.reshape(b, c, f * t)
            x = m.channel_downsampler(x)
            x = x.reshape(b, -1, f, t)
            xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        S = len(m.sources)
        x = x.view(B, S, -1, Fq, Tn) * std[:, None] + mean[:, None]
        xt = xt.view(B, S, -1, mix.shape[-1]) * stdt[:, None] + meant[:, None]
        others = [i for i in range(S) if i != V]
        return x[:, V], x[:, others].sum(1), xt[:, V], xt[:, others].sum(1)

net = Net(model).eval()
torch.manual_seed(0)
mix = torch.randn(1, 2, L) * 0.1
with torch.no_grad():
    z = model._spec(mix)
    spec = model._magnitude(z)
    # Reference: the full model, voice stem.
    ref = model(mix)[0, V]
    sv, so, wv, wo = net(mix, spec)
    zv = model._mask(z, sv[:, None])[:, 0]
    mine = model._ispec(zv, L)[0] + wv[0]
    print("wrapper vs model max err", (mine - ref).abs().max().item(), "ref max", ref.abs().max().item())
    traced = torch.jit.trace(net, (mix, spec))

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="mix", shape=mix.shape), ct.TensorType(name="spec", shape=spec.shape)],
    outputs=[ct.TensorType(name=n) for n in ["voiceSpec", "restSpec", "voiceWave", "restWave"]],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel = cto.linear_quantize_weights(mlmodel, cto.OptimizationConfig(
    global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=1_000_000)))
mlmodel.short_description = "HTDemucs (Meta, MIT) voice / rest separation, one 7.8 s segment at 44.1 kHz"
out = sys.argv[1]
mlmodel.save(out)
pred = mlmodel.predict({"mix": mix.numpy(), "spec": spec.numpy()})
print("coreml vs torch voiceWave max err", np.abs(pred["voiceWave"] - wv.numpy()).max(),
      "voiceSpec max err", np.abs(pred["voiceSpec"] - sv.numpy()).max(), "spec max", sv.abs().max().item())
