# JoeBro header scenes

34 unmodified scene generators and the canvas renderer from bas3line/ascii,
MIT licensed, upstream commit 23ffc851ef4471b6843d9b37aa756077af66bc6f.
The npm 0.4.0 release has fewer scenes than the skill, so this build uses the
matching upstream source. LICENSE.txt ships inside the app's AsciiScenes folder.

Rebuild from this directory with Node/npm and git:

    npm ci
    git clone https://github.com/bas3line/ascii.git ascii-upstream
    git -C ascii-upstream checkout 23ffc851ef4471b6843d9b37aa756077af66bc6f
    node build-scenes.mjs
    cp -R AsciiScenes/. ../../JoeBroMobile/AsciiScenes/

scenes.json lists the library's exact scene names. The bundle is self contained;
WKWebView loads no remote scripts, fonts or data. The native wrapper lives in
JoeBroTheme.swift. Scene choice, pause state, and the black/white backing are
passed to the bundle; scene geometry, glyphs, palettes and motion come from the
library. iOS Reduce Motion and inactive/offscreen views pause playback.

Previous custom scenes were removed. Retired saved selections resolve to Off.
Photo wallpapers suppress header animation. Header sizing remains owned by
JoeBroAgentView's existing measured background, including the top safe area.
