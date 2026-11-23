#!/bin/bash
set -euo pipefail
cp .github/fourier-qa/Bench.swift TapTalk/Services/
ruby - <<'RUBY'
def amend(path, old, new)
  src=File.read(path)
  raise "expected one match in #{path}" unless src.scan(old).size==1
  File.write(path,src.sub(old) {new})
end
path='TapTalk/TapTalkApp.swift'
substr=File.read(path).split('// Shared observable for menu bar',2).last
File.write(path, <<~SWIFT + '// Shared observable for menu bar' + substr)
  import AppKit
  import SwiftUI
  @main
  struct BenchAppEntry {
      @MainActor static func main() {
          let app = NSApplication.shared
          Task { @MainActor in await FourierComparison.run() }
          app.run()
      }
  }
SWIFT
amend('TapTalk/Services/AppController.swift','lazy var recorder = DictationRecorder()','lazy var recorder = DictationRecorder(capture: FourierComparison.capture)')
amend('TapTalk/Services/PasteService.swift','        simulateCmdV()', '        MainActor.assumeIsolated { if FourierComparison.physicalPaste { simulateCmdV() } else { FourierComparison.deliverInAppPaste() } }')
RUBY
curl -fLsS --retry 3 'https://media.githubusercontent.com/media/andrewleech/qwen3-asr-onnx/4aee2ae0c355c7bc33bd5c09befec9e9eabd4b50/tests/fixtures/librispeech_0.wav' -o /tmp/taptalk-speech.wav
echo '799f78ed4beb4de7ceae3a809262d4ce242394342ccd1d58cef7d49dbc2def46  /tmp/taptalk-speech.wav' | shasum -a 256 -c
xcodegen generate
xcodebuild -project TapTalk.xcodeproj -scheme TapTalk -configuration Release -derivedDataPath /tmp/taptalk-build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=NO build >/tmp/taptalk-bench-build.log 2>&1 || { grep 'error:' /tmp/taptalk-bench-build.log | tail -40; tail -25 /tmp/taptalk-bench-build.log; exit 1; }

