# Third-party notices

Grokoo includes Swift adaptations of portions of the following MIT-licensed projects. Their copyright and license texts are retained in `ThirdParty/Licenses/`.

## grokbot-tui

- Source: [smarzban/grokbot-tui](https://github.com/smarzban/grokbot-tui)
- Revision: `b06e2f003c6a5e6fee4368596e2cd8f4d41db722`
- Original files: `src/client/session.ts`, `src/client/http.ts`
- Adapted files: `Grokoo/Gateway/DesktopSessionLoader.swift`, `SafeStorageDecryptor.swift`, `GatewayHTTPClient.swift`
- Adaptations cover desktop session descriptors, Electron Safe Storage parameters and HTTP authentication, implemented with Security, CommonCrypto and URLSession.
- [MIT license and copyright notice](ThirdParty/Licenses/grokbot-tui-MIT.txt)

## Bloub

- Source: [jeremy-prt/bloub](https://github.com/jeremy-prt/bloub)
- Revision: `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`
- Original files: `src/bot/shape.ts`, `skins.ts`, `face.ts`, `eyefit.ts`
- Adapted files: `Grokoo/Rendering/BloubShapeEngine.swift`, `FaceLayer.swift`
- Adaptations cover radial outlines, 64-point sampling, shape interpolation and eye fitting, implemented with Swift and CoreGraphics.
- [MIT license and copyright notice](ThirdParty/Licenses/bloub-MIT.txt)

## Grokoo 1.1 native motion adaptation

- Input: the approved `grokling-animation-kit` 1.0.0 handoff dated 2026-09-18.
- `NativeRestSampler.swift` and the resting geometry/eye-fit constants in `NativeMotionData.swift` adapt the handoff's Bloub `shape`, `states`, `expressions`, `face` and `eyefit` modules under the Bloub MIT notice above.
- The handoff's `official-motion.ts`, `official-trails.ts`, `status-orb.ts` and `status-shapes.ts` supply the approved Working/Done and Thinking/Blocked reference geometry and timing. Their original source and implementation boundaries remain recorded in the handoff's `SOURCE-PROVENANCE.md`; these are project adaptations of publicly observed drawing behavior, not an officially released xAI SDK or an assertion of xAI open-source licensing.
- Native Swift paths, pose sampling and front/back ribbons replace the Web rendering entry. No Web runtime or source article script is bundled in the application.
