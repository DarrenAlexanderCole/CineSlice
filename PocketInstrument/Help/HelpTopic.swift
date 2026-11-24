import Foundation

/// The pages of the manual, in the order a new edit usually visits them.
enum HelpPage: String, CaseIterable {
    case basics, arrange, explore, mix, audio, release

    var title: String {
        switch self {
        case .basics: return "Everywhere"
        case .arrange: return "Arrange"
        case .explore: return "Trim"
        case .mix: return "Mix"
        case .audio: return "Audio"
        case .release: return "Release"
        }
    }

    var intro: String {
        switch self {
        case .basics:
            return "The viewer, the top bar and the transport stay put on every page, so you never lose your place."
        case .arrange:
            return "Line your clips up, choose how each fills the frame, and loop parts of the sequence to watch them."
        case .explore:
            return "Open one clip's whole recording and choose the part you use: its In and Out."
        case .mix:
            return "Cut against music or a click, and balance the music with your clips' own sound."
        case .audio:
            return "Split voices out of a clip's sound, and shape the whole mix with the EQ."
        case .release:
            return "Choose the shape, size, quality and sound of the video, then render, save and share it."
        }
    }
}

/// One control's help: the card shown when it's tapped in help mode, and its entry in the manual.
/// Every control that can be tapped in help mode has one, so the card and the manual never disagree.
enum HelpTopic: String, CaseIterable, Identifiable {
    // Everywhere
    case projects, undoRedo, release, help, viewer, timecode, pictureShape, watch, pages
    case play, jog, frameStep, loop, lane, laneZoom
    // Arrange
    case clips, addClips, split, framing, duplicate, remove, crop
    // Explore
    case filmstrip, trimMusic, trimReadouts, markInOut, trimZoom
    // Mix
    case music, nudge, musicLock, write, editCurve, clearCurve, mixClips, clipFader, musicFader, snap
    // Audio
    case audioPages, audioClips, splitOption, splitFaders, eqCurve, eqKnobs, eqOn, eqFlat
    // Release
    case presets, feedCut, resolution, frameRate, codec, videoBitrate, keyframes, guide
    case sound, audioBitrate, handoff, render

    var id: String { rawValue }

    var page: HelpPage {
        switch self {
        case .projects, .undoRedo, .release, .help, .viewer, .timecode, .pictureShape, .watch, .pages, .play, .jog,
            .frameStep, .loop, .lane, .laneZoom:
            return .basics
        case .clips, .addClips, .split, .framing, .duplicate, .remove, .crop: return .arrange
        case .filmstrip, .trimMusic, .trimReadouts, .markInOut, .trimZoom: return .explore
        case .music, .nudge, .musicLock, .write, .editCurve, .clearCurve, .mixClips, .clipFader, .musicFader, .snap:
            return .mix
        case .audioPages, .audioClips, .splitOption, .splitFaders, .eqCurve, .eqKnobs, .eqOn, .eqFlat: return .audio
        case .presets, .feedCut, .resolution, .frameRate, .codec, .videoBitrate, .keyframes, .guide, .sound,
            .audioBitrate, .handoff, .render:
            return .release
        }
    }

    var title: String {
        switch self {
        case .projects: return "Projects"
        case .undoRedo: return "Undo and redo"
        case .release: return "Release"
        case .help: return "Help"
        case .viewer: return "Viewer"
        case .timecode: return "Timecode"
        case .pictureShape: return "Picture shape"
        case .watch: return "Watch"
        case .pages: return "Pages"
        case .play: return "Play and pause"
        case .jog: return "Jog wheel"
        case .frameStep: return "Frame step"
        case .loop: return "Loop"
        case .lane: return "Sequence lane"
        case .laneZoom: return "Lane zoom"
        case .clips: return "Clips"
        case .addClips: return "Add clips"
        case .split: return "Split"
        case .framing: return "Fill or fit"
        case .duplicate: return "Duplicate"
        case .remove: return "Remove"
        case .crop: return "Crop"
        case .filmstrip: return "Filmstrip"
        case .trimMusic: return "Music under the clip"
        case .trimReadouts: return "In, length, out"
        case .markInOut: return "In and Out"
        case .trimZoom: return "Zoom to clip"
        case .music: return "Music"
        case .nudge: return "Nudge"
        case .musicLock: return "Song position and lock"
        case .write: return "Write"
        case .editCurve: return "Edit curve"
        case .clearCurve: return "Clear curves"
        case .mixClips: return "Clip picker"
        case .clipFader: return "Clip fader"
        case .musicFader: return "Music fader"
        case .snap: return "Snap"
        case .audioPages: return "Split and EQ"
        case .audioClips: return "Clip picker"
        case .splitOption: return "Original or split"
        case .splitFaders: return "Voice and everything else"
        case .eqCurve: return "EQ curve"
        case .eqKnobs: return "EQ knobs"
        case .eqOn: return "EQ on"
        case .eqFlat: return "Flat"
        case .presets: return "Presets"
        case .feedCut: return "Frame"
        case .resolution: return "Resolution"
        case .frameRate: return "Frame rate"
        case .codec: return "Codec"
        case .videoBitrate: return "Video bitrate"
        case .keyframes: return "Keyframe interval"
        case .guide: return "Guide"
        case .sound: return "Sound"
        case .audioBitrate: return "Audio bitrate"
        case .handoff: return "Instagram handoff"
        case .render: return "Render"
        }
    }

    var body: String {
        switch self {
        case .projects:
            return "Back to your list of projects. Everything is saved as you go."
        case .undoRedo:
            return "Steps back or forward through your edits one at a time: a trim, a fader move, a new song. "
                + "Your footage itself is never changed."
        case .release:
            return "Opens Release: choose the video's shape, size, quality and sound, then render it to save or share."
        case .help:
            return "Turns help mode on and off. While it's on, tapping a control explains it instead of using it. "
                + "The manual is in the help bar too."
        case .viewer:
            return "Your sequence as it will be exported. On a vertical sequence the dashed lines mark the 4:5 part "
                + "that Instagram's feed shows."
        case .timecode:
            return "Where the playhead is, in hours:minutes:seconds:frames, over the sequence's total length. "
                + "In Trim it counts through the clip's whole recording."
        case .pictureShape:
            return "Turns the whole sequence between vertical 9:16 and horizontal 16:9. Each clip keeps its framing."
        case .watch:
            return "Just your footage, full screen, playing. Tap for play, In, Out and Done; triple-tap or swipe "
                + "down to come back. A 16:9 edit fills the screen when you turn the phone sideways. Watching is where "
                + "the best edits come from: mark In and Out as moments land."
        case .pages:
            return "Arrange, Trim, Mix and Audio are views of the same edit. Switch whenever you like; the "
                + "picture and the playhead stay put. Trim opens the selected clip."
        case .play:
            return "Plays or pauses. Playback carries on while you edit, so you can keep watching as you work."
        case .jog:
            return "Drag sideways to move a frame at a time. Push it further out and hold to shuttle: it plays "
                + "forwards or backwards, faster the further you push, and stops on a frame when you let go. In Mix, "
                + "with a curve point picked, it moves the point instead."
        case .frameStep:
            return "One frame back or forward."
        case .loop:
            return "Tap to loop the bracketed region of the sequence. Hold for Loop In or Loop Out at the playhead, "
                + "or to loop the selected clip or everything. In Trim it loops the clip from In to Out."
        case .lane:
            return "The whole sequence: clips along the top, the music's waveform below, cuts as ticks, and the "
                + "loop bracket. Drag to scrub. Drag the bracket's handles to set the loop (they catch on cuts). "
                + "Pinch to zoom. In Mix, dragging the waveform slides the music against the picture."
        case .laneZoom:
            return "Magnifies the lane around the playhead (1×, 4×, 16×) for lining things up closer than a frame. "
                + "Pinching the lane zooms too."
        case .clips:
            return "Your sequence in order. Tap a clip to select it and jump to it. Touch and hold, then drag, to "
                + "move it."
        case .addClips:
            return "Brings in videos or photos from Photos or Files. They're copied into the project; the originals "
                + "are never changed."
        case .split:
            return "Cuts the clip under the playhead in two, right there, so each part can be moved, trimmed or "
                + "removed on its own. Both parts keep the clip's framing and sound. It's dark when the playhead "
                + "is on a cut or too close to one."
        case .framing:
            return "Fill covers the frame, cutting off what overhangs. Fit shows the whole picture, with bars where "
                + "it doesn't reach."
        case .duplicate:
            return "Puts a copy of the selected clip right after it, to use the same shot twice."
        case .remove:
            return "Takes the selected clip out of the sequence. Undo brings it back; the original is untouched."
        case .crop:
            return "Pushes in on the selected clip. Drag and pinch the frame over the picture, then tap the tick. "
                + "Reset goes back to the whole frame."
        case .filmstrip:
            return "The selected clip's whole recording. Drag the strip to scrub. Drag the bright handles to set "
                + "where the clip starts (In) and ends (Out); the dimmed parts aren't used."
        case .trimMusic:
            return "The music that plays under each frame of the clip. Moving In slides it, because the In frame "
                + "always plays at the clip's place in the sequence."
        case .trimReadouts:
            return "Where the clip starts and ends in its recording, and how long it plays."
        case .markInOut:
            return "Sets the clip's start (In) or end (Out) at the playhead. Play, and tap them as the moment comes."
        case .trimZoom:
            return "Fits the filmstrip to around In and Out, so the handles move in finer steps on a long recording."
        case .music:
            return "Chooses what to cut against: a song on your phone (My Music), a click at your tempo (Quick "
                + "Click), or Billboards, which names a song you'll add in Instagram and captures its rhythm as you "
                + "tap along."
        case .nudge:
            return "Moves the music one frame, or 10 milliseconds, earlier or later against the picture."
        case .musicLock:
            return "Shows where the song sits: SONG AT 0 is how far into the song the video starts; SONG IN is when "
                + "the song comes in. Tap to lock it there; nothing slides or nudges it until you unlock it."
        case .write:
            return "Arms recording. With Write on, move a fader while playing and your moves are recorded as a "
                + "curve. Inside a recorded pass the fader reads AUTO and follows it; with Write off, moving the "
                + "fader there raises or lowers that whole pass."
        case .editCurve:
            return "Opens the clip's or the music's level curve in the lane. Drag a point to move it, drag "
                + "elsewhere to draw, tap to add a point, double-tap a point to delete it. Tap a point and the jog "
                + "wheel inches it in time."
        case .clearCurve:
            return "Erases recorded level curves: the selected clip's, every clip's, or the music's."
        case .mixClips:
            return "Chooses which clip the CLIP fader sets. Each tile shows that clip's level."
        case .clipFader:
            return "The level of the selected clip's own sound."
        case .musicFader:
            return "The level of the music. With music in the mix, Release can still leave it out of the file."
        case .snap:
            return "With a click or tapped guide, scrubbing and the loop handles catch on its beats."
        case .audioPages:
            return "SPLIT works on one clip's sound. EQ shapes the whole mix."
        case .audioClips:
            return "Chooses the clip to work on. Each tile shows whether its sound plays as recorded or split."
        case .splitOption:
            return "Original plays the sound as recorded. Split separates voices from everything else, on your "
                + "phone, with a fader for each; it starts with the voices out. Splitting takes a moment per clip, "
                + "and the clip is silent until it's ready."
        case .splitFaders:
            return "The levels of the voices and of everything else in a split clip, e.g. voices down for someone "
                + "talking behind the camera."
        case .eqCurve:
            return "What the EQ does to the sound, from low (left) to high (right). Above the line is louder, below "
                + "is quieter."
        case .eqKnobs:
            return "LOW CUT removes rumble below its frequency. LOW and HIGH raise or lower the bass and treble. "
                + "MID, MID GAIN and WIDTH boost or cut one band: where it is, by how much, and how wide. Drag a "
                + "knob up or right to turn it up, down or left to turn it down; double-tap it to reset."
        case .eqOn:
            return "Switches the EQ off and on, to hear the difference."
        case .eqFlat:
            return "Sets every band back to no change."
        case .presets:
            return "One tap to a common shape and size, with the bitrate on Auto. A 16:9 preset turns the sequence "
                + "horizontal. Fine-tune with the settings below."
        case .feedCut:
            return "Exports the whole vertical frame for Reels and Stories, or just its centre 4:5 for the feed."
        case .resolution:
            return "The video's size, by its short side: 1080p is 1080 pixels, 4K is 2160. Bigger keeps more "
                + "detail and makes a bigger file; above your footage's own size it only enlarges."
        case .frameRate:
            return "Frames per second. 24 looks like cinema, 30 is standard for phones, 60 is smoothest for fast "
                + "motion. Above your footage's own rate it repeats frames."
        case .codec:
            return "H.264 plays everywhere. HEVC makes about a third smaller files at the same quality, but some "
                + "older computers and apps can't open it."
        case .videoBitrate:
            return "How much data each second of picture can use: more keeps fine detail and motion clean, less "
                + "makes a smaller file. Auto picks a high-quality rate for the size and frame rate."
        case .keyframes:
            return "How often a complete frame is stored. Shorter scrubs more smoothly in other editors; longer "
                + "makes a smaller file."
        case .guide:
            return "What your settings will give: a quality rating, the estimated file size, and notes on settings "
                + "that add size without adding picture."
        case .sound:
            return "What sound goes in the file: none (to add a licensed song in Instagram), your clips' own sound, "
                + "or clips and music exactly as you hear them."
        case .audioBitrate:
            return "How much data the sound can use. 128 kbps is fine for speech; 256 is clear for music."
        case .handoff:
            return "Where the song should start when you add it in Instagram, and the steps to line it up by hand. "
                + "Apps can't attach Instagram's licensed music for you."
        case .render:
            return "Makes the video. Then save it to Photos, share it, or open Instagram on it."
        }
    }
}
