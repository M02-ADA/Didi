# Approved Lean introduction

`lean.mp4` is the supplied source, unchanged. Runtime uses `lean-introduction.mov`: the same 180 frames / 3 seconds / 60 fps / 1210 × 834 with an offline coverage matte from the white-on-black source, premultiplied cream #FEE3BB, encoded as HEVC with alpha. No audio track is copied. There is no runtime keying.

Run prepare-lean-alpha.swift with Xcode Swift, passing source and unused destination paths. The source file remains unchanged. The bundled poster is a decoded frame at 1 second (used for Reduce Motion / media fallback). It retains transparency. Solo clips to the first silhouette; it does not invent another player.

See Apple: https://developer.apple.com/videos/play/wwdc2019/506/ for AVPlayer/AVPlayerLayer HEVC-alpha support.
