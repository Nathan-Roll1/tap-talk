#!/bin/bash
set -euo pipefail
cp .github/fourier-qa/Bench.swift TapTalk/Services/
ruby - <<'RUBY'
def amend(path, old, new)
  src=File.read(path)
  raise "expected one match in #{path}" unless src.scan(old).size==1
  File.write(path,src.sub(old) {new})
end
amend('TapTalk/TapTalkApp.swift','AppController.shared.setup()','Task { @MainActor in await FourierComparison.run() }')
amend('TapTalk/Services/AppController.swift','lazy var recorder = DictationRecorder()','lazy var recorder = DictationRecorder(capture: FourierComparison.capture)')
amend('TapTalk/Services/PasteService.swift','        simulateCmdV()', '        if FourierComparison.physicalPaste { simulateCmdV() } else { MainActor.assumeIsolated { FourierComparison.deliverInAppPaste() } }')
RUBY
curl -fLsS --retry 3 'https://media.githubusercontent.com/media/andrewleech/qwen3-asr-onnx/4aee2ae0c355c7bc33bd5c09befec9e9eabd4b50/tests/fixtures/librispeech_0.wav' -o /tmp/taptalk-speech.wav
echo '799f78ed4beb4de7ceae3a809262d4ce242394342ccd1d58cef7d49dbc2def46  /tmp/taptalk-speech.wav' | shasum -a 256 -c
xcodegen generate
xcodebuild -project TapTalk.xcodeproj -scheme TapTalk -configuration Release -derivedDataPath /tmp/taptalk-build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=NO build >/tmp/taptalk-bench-build.log 2>&1 || { grep 'error:' /tmp/taptalk-bench-build.log | tail -40; tail -25 /tmp/taptalk-bench-build.log; exit 1; }
/tmp/taptalk-build/Build/Products/Release/TapTalk.app/Contents/MacOS/TapTalk | tee /tmp/taptalk-bench-run.log
