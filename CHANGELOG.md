# Changelog

## [0.23.0](https://github.com/unicornops/shuffleboard/compare/v0.22.0...v0.23.0) (2026-10-12)


### Features

* **offline:** keep a copy of the boards on the Mac and work read-only offline ([#186](https://github.com/unicornops/shuffleboard/issues/186)) ([5584578](https://github.com/unicornops/shuffleboard/commit/5584578fc310a6014ef0d474786399134138dcde))

## [0.22.0](https://github.com/unicornops/shuffleboard/compare/v0.21.4...v0.22.0) (2026-10-12)


### Features

* **comments:** [@mention](https://github.com/mention) people in comments ([#184](https://github.com/unicornops/shuffleboard/issues/184)) ([6580733](https://github.com/unicornops/shuffleboard/commit/65807334f1834ac9dc6ba0f076faa6e5399bd864)), closes [#163](https://github.com/unicornops/shuffleboard/issues/163)
* **settings:** a Settings window for refreshing, launch account and updates ([#183](https://github.com/unicornops/shuffleboard/issues/183)) ([0a5f851](https://github.com/unicornops/shuffleboard/commit/0a5f851ec3c18b76379142e7fb5170ae12c05794)), closes [#165](https://github.com/unicornops/shuffleboard/issues/165)

## [0.21.4](https://github.com/unicornops/shuffleboard/compare/v0.21.3...v0.21.4) (2026-10-12)


### Bug Fixes

* **boards:** keep the board's buttons still while lists refresh ([#181](https://github.com/unicornops/shuffleboard/issues/181)) ([dab3398](https://github.com/unicornops/shuffleboard/commit/dab3398a8c320efe451e0a56ae7c1196184710e2))

## [0.21.3](https://github.com/unicornops/shuffleboard/compare/v0.21.2...v0.21.3) (2026-10-11)


### Bug Fixes

* **keyboard:** stop the toolbar flickering while moving cards ([#179](https://github.com/unicornops/shuffleboard/issues/179)) ([b8ca36c](https://github.com/unicornops/shuffleboard/commit/b8ca36cb44f1c064f407dcff842d189a11472288))

## [0.21.2](https://github.com/unicornops/shuffleboard/compare/v0.21.1...v0.21.2) (2026-10-11)


### Bug Fixes

* **notifications:** remind about the same cards Deck notifies you about ([#177](https://github.com/unicornops/shuffleboard/issues/177)) ([1bbf4ee](https://github.com/unicornops/shuffleboard/commit/1bbf4ee9451061905d9ed0084f175b7494e2eca4))

## [0.21.1](https://github.com/unicornops/shuffleboard/compare/v0.21.0...v0.21.1) (2026-10-10)


### Bug Fixes

* **notifications:** match your user id, and sum up overdue cards at startup ([#175](https://github.com/unicornops/shuffleboard/issues/175)) ([b911880](https://github.com/unicornops/shuffleboard/commit/b9118800c6165e566725d961db23562b2e527e06))

## [0.21.0](https://github.com/unicornops/shuffleboard/compare/v0.20.1...v0.21.0) (2026-10-09)


### Features

* **keyboard:** menu commands and shortcuts for cards, lists and boards ([#171](https://github.com/unicornops/shuffleboard/issues/171)) ([3ca7720](https://github.com/unicornops/shuffleboard/commit/3ca7720a50c9a93d40e7ce85f649efe940353c04))
* **notifications:** macOS notifications for due and newly assigned cards ([#173](https://github.com/unicornops/shuffleboard/issues/173)) ([c026f76](https://github.com/unicornops/shuffleboard/commit/c026f7687e0e700020444d7e7e382b5b15fe270f)), closes [#157](https://github.com/unicornops/shuffleboard/issues/157)
* **search:** search cards across all boards ([#172](https://github.com/unicornops/shuffleboard/issues/172)) ([3dbd7d3](https://github.com/unicornops/shuffleboard/commit/3dbd7d35168b2094bc7e20d3a7079188efcf823c))

## [0.20.1](https://github.com/unicornops/shuffleboard/compare/v0.20.0...v0.20.1) (2026-10-09)


### Bug Fixes

* **keychain:** stay signed in after quitting ([#169](https://github.com/unicornops/shuffleboard/issues/169)) ([1151639](https://github.com/unicornops/shuffleboard/commit/1151639f2c5d0a9f2b5ce88aeada7b4ad7c017a8))

## [0.20.0](https://github.com/unicornops/shuffleboard/compare/v0.19.0...v0.20.0) (2026-10-08)


### Features

* **keychain:** keep credentials in the data protection keychain ([#166](https://github.com/unicornops/shuffleboard/issues/166)) ([719c96c](https://github.com/unicornops/shuffleboard/commit/719c96c868465dc33e9fe7fc6ecf841e185a3a95))

## [0.19.0](https://github.com/unicornops/shuffleboard/compare/v0.18.0...v0.19.0) (2026-10-08)


### Features

* **attachments:** restore a deleted attachment ([#152](https://github.com/unicornops/shuffleboard/issues/152)) ([34ff29e](https://github.com/unicornops/shuffleboard/commit/34ff29ebe0544204d01afd2cb90b6cab8a0c3e7d))
* **boards:** duplicate a board ([#153](https://github.com/unicornops/shuffleboard/issues/153)) ([7ba3e69](https://github.com/unicornops/shuffleboard/commit/7ba3e69802bf6ba35fd8887d030c3406fdb11810)), closes [#137](https://github.com/unicornops/shuffleboard/issues/137)
* **cards:** show and edit the card start date ([#150](https://github.com/unicornops/shuffleboard/issues/150)) ([ae986d2](https://github.com/unicornops/shuffleboard/commit/ae986d279c1a61e1b4808314d7be34beba6efb7e))


### Bug Fixes

* **cards:** focus the new card's title field after Add card ([#148](https://github.com/unicornops/shuffleboard/issues/148)) ([269b9c5](https://github.com/unicornops/shuffleboard/commit/269b9c5eeeeb2acfefb2b2ce1dd87a5af36a5a6d)), closes [#140](https://github.com/unicornops/shuffleboard/issues/140)


### Performance Improvements

* **refresh:** skip downloading lists when the board list is unchanged ([#149](https://github.com/unicornops/shuffleboard/issues/149)) ([5c22755](https://github.com/unicornops/shuffleboard/commit/5c227556f569cf36286c05e6cf05aa34aecccb0b)), closes [#141](https://github.com/unicornops/shuffleboard/issues/141)

## [0.18.0](https://github.com/unicornops/shuffleboard/compare/v0.17.4...v0.18.0) (2026-10-08)


### Features

* **boards:** rename a board and change its colour ([#143](https://github.com/unicornops/shuffleboard/issues/143)) ([148217a](https://github.com/unicornops/shuffleboard/commit/148217aca974db0188b1a46f83d3b16a32cb5154)), closes [#133](https://github.com/unicornops/shuffleboard/issues/133)
* **boards:** restore deleted boards ([#146](https://github.com/unicornops/shuffleboard/issues/146)) ([e0df780](https://github.com/unicornops/shuffleboard/commit/e0df780dc0bf4bb5136c3c005c377bdfc59c1c25))
* **labels:** edit and delete labels ([#145](https://github.com/unicornops/shuffleboard/issues/145)) ([5e95bfa](https://github.com/unicornops/shuffleboard/commit/5e95bfa96d68876bccac98f05b29b2fcdd56ef95))
* **lists:** rename a list ([#144](https://github.com/unicornops/shuffleboard/issues/144)) ([90d5dab](https://github.com/unicornops/shuffleboard/commit/90d5dabbf4c1c950d976ecb5301dcdbfd48f86c9)), closes [#134](https://github.com/unicornops/shuffleboard/issues/134)

## [0.17.4](https://github.com/unicornops/shuffleboard/compare/v0.17.3...v0.17.4) (2026-10-07)


### Bug Fixes

* **cards:** moving a card to another list snapped back on some servers ([#132](https://github.com/unicornops/shuffleboard/issues/132)) ([49b3c45](https://github.com/unicornops/shuffleboard/commit/49b3c45e6ee849f3f44fb3f474364cc41927ed86)), closes [#131](https://github.com/unicornops/shuffleboard/issues/131)


### Chores

* **cards:** log card drags and drops ([#129](https://github.com/unicornops/shuffleboard/issues/129)) ([b5e63d5](https://github.com/unicornops/shuffleboard/commit/b5e63d58080bd5169d3de59a840fb602b8467bb5))

## [0.17.3](https://github.com/unicornops/shuffleboard/compare/v0.17.2...v0.17.3) (2026-10-07)


### Bug Fixes

* **cards:** moving a card to another list could do nothing ([#126](https://github.com/unicornops/shuffleboard/issues/126)) ([8cefe64](https://github.com/unicornops/shuffleboard/commit/8cefe64f362840c45fc874db931a77a7b0285bd8))

## [0.17.2](https://github.com/unicornops/shuffleboard/compare/v0.17.1...v0.17.2) (2026-10-07)


### Bug Fixes

* **accounts:** a second account on the same server acted as the first ([#122](https://github.com/unicornops/shuffleboard/issues/122)) ([2009ab4](https://github.com/unicornops/shuffleboard/commit/2009ab49e55fabc6978dacbf0d8bd11f2c447162)), closes [#121](https://github.com/unicornops/shuffleboard/issues/121)
* **attachments:** uploads failed with Deck 1.17 and 1.18 ([#124](https://github.com/unicornops/shuffleboard/issues/124)) ([06fda70](https://github.com/unicornops/shuffleboard/commit/06fda70726d53d52702f4fc2b1d1b6e2e2eb8405)), closes [#123](https://github.com/unicornops/shuffleboard/issues/123)

## [0.17.1](https://github.com/unicornops/shuffleboard/compare/v0.17.0...v0.17.1) (2026-10-07)


### Bug Fixes

* **cards:** dragging a card to another list snaps back ([#117](https://github.com/unicornops/shuffleboard/issues/117)) ([49b7c40](https://github.com/unicornops/shuffleboard/commit/49b7c40cc2794794dabdb1d04036dccbacffa641))
* **release:** retry notarization requests instead of failing on one ([#115](https://github.com/unicornops/shuffleboard/issues/115)) ([2633e17](https://github.com/unicornops/shuffleboard/commit/2633e17e298491bf2bfcb20c0b043f3a5226172d))

## [0.17.0](https://github.com/unicornops/shuffleboard/compare/v0.16.0...v0.17.0) (2026-10-06)


### Features

* **accounts:** multiple accounts ([#114](https://github.com/unicornops/shuffleboard/issues/114)) ([c9856d0](https://github.com/unicornops/shuffleboard/commit/c9856d0ee2f791da3cf00d00964b18e95c454879)), closes [#81](https://github.com/unicornops/shuffleboard/issues/81)
* **boards:** board sharing ([#113](https://github.com/unicornops/shuffleboard/issues/113)) ([70bf63e](https://github.com/unicornops/shuffleboard/commit/70bf63e597ab9149a853e3184f52dd8c1e62902a)), closes [#80](https://github.com/unicornops/shuffleboard/issues/80)
* **cards:** archive cards and browse archived cards ([#112](https://github.com/unicornops/shuffleboard/issues/112)) ([92bc8ff](https://github.com/unicornops/shuffleboard/commit/92bc8ff1047b2fd3e8ebe67da426dc806f53d80c)), closes [#76](https://github.com/unicornops/shuffleboard/issues/76)
* **cards:** comments ([#109](https://github.com/unicornops/shuffleboard/issues/109)) ([129c8f4](https://github.com/unicornops/shuffleboard/commit/129c8f4f2483f0c46e59110ce08283b365f80bca)), closes [#75](https://github.com/unicornops/shuffleboard/issues/75)
* **cards:** render Markdown descriptions ([#110](https://github.com/unicornops/shuffleboard/issues/110)) ([305fc65](https://github.com/unicornops/shuffleboard/commit/305fc65dc6e73e5a3e28533abe8debb629c8e490))
* refresh automatically when changes are made elsewhere ([#107](https://github.com/unicornops/shuffleboard/issues/107)) ([489397c](https://github.com/unicornops/shuffleboard/commit/489397c0e6f0c1cdd7369f119dba7d52dd657a60)), closes [#79](https://github.com/unicornops/shuffleboard/issues/79)
* search and filter cards ([#111](https://github.com/unicornops/shuffleboard/issues/111)) ([eed648e](https://github.com/unicornops/shuffleboard/commit/eed648e5d84439a9b0ae123ca46fc1d3da58c496)), closes [#78](https://github.com/unicornops/shuffleboard/issues/78)

## [0.16.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.15.0...v0.16.0) (2026-10-05)


### Features

* **cards:** assign users ([#106](https://github.com/unicornops/nextcloud-deck-macos/issues/106)) ([b5014ec](https://github.com/unicornops/nextcloud-deck-macos/commit/b5014ec82762cd2f5146171e69abe3c6aa2d49a1)), closes [#74](https://github.com/unicornops/nextcloud-deck-macos/issues/74)
* **cards:** due dates and done state ([#105](https://github.com/unicornops/nextcloud-deck-macos/issues/105)) ([16eab65](https://github.com/unicornops/nextcloud-deck-macos/commit/16eab658cfefa2956a4a2245ea0a938a38a9d8f5)), closes [#73](https://github.com/unicornops/nextcloud-deck-macos/issues/73)
* in-app updates with Sparkle ([#103](https://github.com/unicornops/nextcloud-deck-macos/issues/103)) ([4c4ffb4](https://github.com/unicornops/nextcloud-deck-macos/commit/4c4ffb44f9251ee3fd014a8dbb4c2a72f8effe01)), closes [#71](https://github.com/unicornops/nextcloud-deck-macos/issues/71)


### Chores

* adopt the Swift 6 language mode ([#100](https://github.com/unicornops/nextcloud-deck-macos/issues/100)) ([349e87b](https://github.com/unicornops/nextcloud-deck-macos/commit/349e87b75ac7eb6cd29ba059a0c64928c46e1730)), closes [#69](https://github.com/unicornops/nextcloud-deck-macos/issues/69)
* **deps:** update GitHub Actions to their latest releases ([#102](https://github.com/unicornops/nextcloud-deck-macos/issues/102)) ([76372c0](https://github.com/unicornops/nextcloud-deck-macos/commit/76372c078c03bc9f4d5f66857967db7b217c48cd)), closes [#70](https://github.com/unicornops/nextcloud-deck-macos/issues/70)

## [0.15.0](https://github.com/unicornops/shuffleboard/compare/v0.14.1...v0.15.0) (2026-10-03)


### Features

* rename the app to Shuffleboard ([#98](https://github.com/unicornops/shuffleboard/issues/98)) ([ecc5a92](https://github.com/unicornops/shuffleboard/commit/ecc5a922153bfe3cff8adc01b1dbfbe963855773)), closes [#66](https://github.com/unicornops/shuffleboard/issues/66)


### Bug Fixes

* **attachments:** only fall back when the internal route is missing ([#85](https://github.com/unicornops/shuffleboard/issues/85)) ([505ae35](https://github.com/unicornops/shuffleboard/commit/505ae35372251b3370156cf56b7f738cb27b3eaf)), closes [#55](https://github.com/unicornops/shuffleboard/issues/55)
* **auth:** keep login polling through transient errors and allow cancel ([#89](https://github.com/unicornops/shuffleboard/issues/89)) ([cab2a45](https://github.com/unicornops/shuffleboard/commit/cab2a454c35973b96d4f0ee9c4a6cb4237a5d3e8)), closes [#59](https://github.com/unicornops/shuffleboard/issues/59)
* **auth:** revoke the app password on sign out ([#88](https://github.com/unicornops/shuffleboard/issues/88)) ([c262739](https://github.com/unicornops/shuffleboard/commit/c26273956b0b4a96ca85d57c3dcc604456e36385)), closes [#58](https://github.com/unicornops/shuffleboard/issues/58)
* **auth:** sign out when the app password is revoked or expires ([#87](https://github.com/unicornops/shuffleboard/issues/87)) ([844eb21](https://github.com/unicornops/shuffleboard/commit/844eb212dc3ca65e19a31742db107117b2845d7e)), closes [#57](https://github.com/unicornops/shuffleboard/issues/57)
* **boards:** stop lists flashing empty and racing between boards ([#86](https://github.com/unicornops/shuffleboard/issues/86)) ([de22731](https://github.com/unicornops/shuffleboard/commit/de22731f6a9b43219acfbba58328927f5f7dcf46)), closes [#56](https://github.com/unicornops/shuffleboard/issues/56)
* **cards:** send the full card when saving edits ([#82](https://github.com/unicornops/shuffleboard/issues/82)) ([05c1c3b](https://github.com/unicornops/shuffleboard/commit/05c1c3b5fff393daed5559f9bc39eebfac7203d7)), closes [#53](https://github.com/unicornops/shuffleboard/issues/53)
* **keychain:** store credentials under the app's own service ([#91](https://github.com/unicornops/shuffleboard/issues/91)) ([fd81d9f](https://github.com/unicornops/shuffleboard/commit/fd81d9f283a7a19ea3b1c59e2b8ce8d0d939981e)), closes [#61](https://github.com/unicornops/shuffleboard/issues/61)
* **stacks:** reload lists when a reorder can't be saved ([#90](https://github.com/unicornops/shuffleboard/issues/90)) ([1732215](https://github.com/unicornops/shuffleboard/commit/17322155b90de836ad103910413ebe6bef7123d5)), closes [#60](https://github.com/unicornops/shuffleboard/issues/60)
* state the GPL-3.0 licence consistently ([#96](https://github.com/unicornops/shuffleboard/issues/96)) ([88eb794](https://github.com/unicornops/shuffleboard/commit/88eb794b51c5bbd5cb07fc1f81f230cc84ed8609)), closes [#65](https://github.com/unicornops/shuffleboard/issues/65)
* **ui:** don't call soft-deleted items permanently deleted ([#95](https://github.com/unicornops/shuffleboard/issues/95)) ([c4bd4bf](https://github.com/unicornops/shuffleboard/commit/c4bd4bf32e455c2452802e3248f75ec5dfdad662)), closes [#64](https://github.com/unicornops/shuffleboard/issues/64)
* **ui:** show errors from board and card actions ([#84](https://github.com/unicornops/shuffleboard/issues/84)) ([3e28df7](https://github.com/unicornops/shuffleboard/commit/3e28df7ee77bc9692a3cc3428924f6c4657db762)), closes [#54](https://github.com/unicornops/shuffleboard/issues/54)


### Chores

* **auth:** remove the unused password sign-in flow ([#94](https://github.com/unicornops/shuffleboard/issues/94)) ([08a1c5a](https://github.com/unicornops/shuffleboard/commit/08a1c5a1f151c0b6b49ea4fc6dc5c60ed5605b3c)), closes [#63](https://github.com/unicornops/shuffleboard/issues/63)


### Refactoring

* **api:** use only the documented Deck REST API ([#93](https://github.com/unicornops/shuffleboard/issues/93)) ([ba40e00](https://github.com/unicornops/shuffleboard/commit/ba40e008dc6e3fb6b9f7e500561521c98a2aecbb))

## [0.14.1](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.14.0...v0.14.1) (2026-03-17)


### Chores

* **deps:** bump actions/upload-artifact from 4.6.2 to 7.0.0 ([#43](https://github.com/unicornops/nextcloud-deck-macos/issues/43)) ([764570e](https://github.com/unicornops/nextcloud-deck-macos/commit/764570ed49cdd75487a904bcbb498dfe29466899))

## [0.14.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.13.2...v0.14.0) (2026-03-16)


### Features

* **stacks:** add drag-and-drop stack reordering ([#44](https://github.com/unicornops/nextcloud-deck-macos/issues/44)) ([8a75e0a](https://github.com/unicornops/nextcloud-deck-macos/commit/8a75e0a9c6313d2886cb735ed8d53643324d9d5e))

## [0.13.2](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.13.1...v0.13.2) (2026-03-11)


### Chores

* add SwiftFormat, SwiftLint, and pre-commit config ([#40](https://github.com/unicornops/nextcloud-deck-macos/issues/40)) ([489929a](https://github.com/unicornops/nextcloud-deck-macos/commit/489929a35c3c8c0d6485753393413c506a784a92))
* **tooling:** add PMD CPD and shared decoding helpers ([#42](https://github.com/unicornops/nextcloud-deck-macos/issues/42)) ([64e1ce7](https://github.com/unicornops/nextcloud-deck-macos/commit/64e1ce7215ba447afeaac0585082602e5ef87a3a))

## [0.13.1](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.13.0...v0.13.1) (2026-03-11)


### Chores

* **ci:** pin GitHub Actions and add dependabot config ([#38](https://github.com/unicornops/nextcloud-deck-macos/issues/38)) ([1f0a138](https://github.com/unicornops/nextcloud-deck-macos/commit/1f0a138324b7488220966dd49159c522cd28729e))

## [0.13.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.12.0...v0.13.0) (2026-03-11)


### Features

* **attachments:** Add attachments handling ([#36](https://github.com/unicornops/nextcloud-deck-macos/issues/36)) ([55fb533](https://github.com/unicornops/nextcloud-deck-macos/commit/55fb533ac796a480efb4a2e99484abee3b8863a4))

## [0.12.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.11.0...v0.12.0) (2026-03-09)


### Features

* **cards:** enable drag-and-drop reordering within stacks ([#34](https://github.com/unicornops/nextcloud-deck-macos/issues/34)) ([2bb7215](https://github.com/unicornops/nextcloud-deck-macos/commit/2bb7215caff9d9fec8a05a27cf8e79fb5f02e0dc))

## [0.11.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.10.0...v0.11.0) (2026-03-09)


### Features

* **auth:** simplify login to browser-based flow only ([#32](https://github.com/unicornops/nextcloud-deck-macos/issues/32)) ([f7a637a](https://github.com/unicornops/nextcloud-deck-macos/commit/f7a637abeef7a503b4f120cd590af1423f36d8bd))

## [0.10.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.9.2...v0.10.0) (2026-03-09)


### Features

* **boards:** add add, archive, unarchive, and delete board actions ([#30](https://github.com/unicornops/nextcloud-deck-macos/issues/30)) ([eaa3e8f](https://github.com/unicornops/nextcloud-deck-macos/commit/eaa3e8f4b5d6b65550d40c15ac057ffe2c31cdd9))

## [0.9.2](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.9.1...v0.9.2) (2026-03-08)


### Bug Fixes

* **ui:** make CardRowView accessible as a button ([#28](https://github.com/unicornops/nextcloud-deck-macos/issues/28)) ([fdd0868](https://github.com/unicornops/nextcloud-deck-macos/commit/fdd0868e14b54c6a0154836db7e9f6549ad3e5a7))

## [0.9.1](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.9.0...v0.9.1) (2026-03-08)


### Bug Fixes

* **build:** add build info shell phase and plist loading ([#26](https://github.com/unicornops/nextcloud-deck-macos/issues/26)) ([88ad98a](https://github.com/unicornops/nextcloud-deck-macos/commit/88ad98afba00e3f6d05836916bb55fdab124a6a5))

## [0.9.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.8.0...v0.9.0) (2026-03-08)


### Features

* **ui:** add About sheet with build metadata ([#24](https://github.com/unicornops/nextcloud-deck-macos/issues/24)) ([67b59b1](https://github.com/unicornops/nextcloud-deck-macos/commit/67b59b1e95192a578c4bf9a1c262726f045f8f75))

## [0.8.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.7.0...v0.8.0) (2026-03-08)


### Features

* **cards:** enable drag and drop to move cards between stacks ([#22](https://github.com/unicornops/nextcloud-deck-macos/issues/22)) ([8d4aa66](https://github.com/unicornops/nextcloud-deck-macos/commit/8d4aa6645abaef1def73f55db26d3ace4bc47504))

## [0.7.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.6.0...v0.7.0) (2026-03-08)


### Features

* enforce HTTPS for credential storage and add entitlements ([#20](https://github.com/unicornops/nextcloud-deck-macos/issues/20)) ([048b711](https://github.com/unicornops/nextcloud-deck-macos/commit/048b711ce9be36cc2590046a7738d82fbc3275a3))

## [0.6.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.5.0...v0.6.0) (2026-03-08)


### Features

* enhance KeychainStorage for credential management ([#18](https://github.com/unicornops/nextcloud-deck-macos/issues/18)) ([0dfa2e2](https://github.com/unicornops/nextcloud-deck-macos/commit/0dfa2e20dc0015eeb77c4b2789a9c75728fea0d9))

## [0.5.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.4.1...v0.5.0) (2026-03-08)


### Features

* add label management functionality ([#17](https://github.com/unicornops/nextcloud-deck-macos/issues/17)) ([d7b0690](https://github.com/unicornops/nextcloud-deck-macos/commit/d7b06906c84b3555cde854655caec4fb51178061))


### Chores

* update product bundle identifier and remove unused sourceTree entries ([#15](https://github.com/unicornops/nextcloud-deck-macos/issues/15)) ([53cd7f8](https://github.com/unicornops/nextcloud-deck-macos/commit/53cd7f899cd892b03ca2d460843a04495d492b44))

## [0.4.1](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.4.0...v0.4.1) (2026-03-07)


### Bug Fixes

* update release-please configuration and workflows ([#13](https://github.com/unicornops/nextcloud-deck-macos/issues/13)) ([3725e74](https://github.com/unicornops/nextcloud-deck-macos/commit/3725e7481f5ef11c683138c4f8cb37ca91ec6ac9))

## [0.4.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.3.0...v0.4.0) (2026-03-07)


### Features

* add card deletion functionality ([eb46d2e](https://github.com/unicornops/nextcloud-deck-macos/commit/eb46d2ebbe71197ea345cc45ec7bb89ab18a68be))
* add card deletion functionality ([5a77692](https://github.com/unicornops/nextcloud-deck-macos/commit/5a776927877d7b79e7f48174990efcaec0f9b2b7))
* implement stack deletion functionality ([dcaf32f](https://github.com/unicornops/nextcloud-deck-macos/commit/dcaf32f75e9966c84247ce2b61cb70c6a45f0102))
* implement stack deletion functionality ([390bc9e](https://github.com/unicornops/nextcloud-deck-macos/commit/390bc9e7e7533e38783a4b84e8df8a67abfe664c))

## [0.3.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.2.1...v0.3.0) (2026-03-07)


### Features

* enhance URL handling in DeckAPI ([7280395](https://github.com/unicornops/nextcloud-deck-macos/commit/7280395ce7c3c53419ff201642c13a51ba97fa44))
* enhance URL handling in DeckAPI ([a91dd65](https://github.com/unicornops/nextcloud-deck-macos/commit/a91dd65d48af8103e7c984e00fcfdddc1c4702db))

## [0.2.1](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.2.0...v0.2.1) (2026-03-07)


### Bug Fixes

* update GitHub Actions workflow for release builds ([9240a90](https://github.com/unicornops/nextcloud-deck-macos/commit/9240a909db370d15ae960b1243918c267bb0873c))
* update GitHub Actions workflow for release builds ([751834c](https://github.com/unicornops/nextcloud-deck-macos/commit/751834c52f82bb6e0c1db444b35119d3e3432fdc))

## [0.2.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.1.0...v0.2.0) (2026-03-07)


### Features

* add scripts for DMG creation and app icon generation ([f8822e0](https://github.com/unicornops/nextcloud-deck-macos/commit/f8822e00e963b6d5082e092d759caa6e9c6ea39b))
* add scripts for DMG creation and app icon generation ([4162466](https://github.com/unicornops/nextcloud-deck-macos/commit/4162466af0c63163b8b638e43a0fd9770ff95a8e))

## [0.1.0](https://github.com/unicornops/nextcloud-deck-macos/compare/v0.0.1...v0.1.0) (2026-03-07)


### Features

* Adding License ([bd24cd1](https://github.com/unicornops/nextcloud-deck-macos/commit/bd24cd18e1d1f56c11c0fbf35a54ecb45f5950eb))
* enhance StackColumnView and CardRowView with hover effects and styling improvements ([e1c31d6](https://github.com/unicornops/nextcloud-deck-macos/commit/e1c31d6dd1f64f0425cd6f1301ceaf3e46224d7a))
* enhance StackColumnView and CardRowView with hover effects and styling improvements ([73e84f4](https://github.com/unicornops/nextcloud-deck-macos/commit/73e84f4482d0c0ba1fd4076e7c7ab7ad38ff7635))
* improve accessibility and UI elements across various views ([a626266](https://github.com/unicornops/nextcloud-deck-macos/commit/a62626657e1ccbf3c22107dfaf0ad4892fe45d11))
* initial commit ([3df27a5](https://github.com/unicornops/nextcloud-deck-macos/commit/3df27a559bcb6a894bc89ac8bddd07f4f81d3bd7))
* update createStack method to return success status and improve error handling in NewStackSheet ([773d9ca](https://github.com/unicornops/nextcloud-deck-macos/commit/773d9ca9135c57b05b6d1e01fa434a53d09d82ae))


### Bug Fixes

* update release-please configuration to include package settings ([1fb0f82](https://github.com/unicornops/nextcloud-deck-macos/commit/1fb0f82ba3003db76d1a7ef576742ac2e9225a6e))


### Miscellaneous

* add release please manifest file ([f3e9cf1](https://github.com/unicornops/nextcloud-deck-macos/commit/f3e9cf1979f87a317b86f05f3b5c1065ee1f10c3))

## [Unreleased]

### Features

- Native macOS app for Nextcloud Deck with Trello-like board interface
