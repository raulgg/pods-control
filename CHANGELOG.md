# Changelog

## [0.6.0](https://github.com/raulgg/pods-control/compare/v0.5.0...v0.6.0) (2026-10-05)


### Features

* cycle listening modes in the order given to --modes ([#154](https://github.com/raulgg/pods-control/issues/154)) ([ee33b13](https://github.com/raulgg/pods-control/commit/ee33b135446c1ede9e2df5c6a5f05930d776e1e8))
* explain bad-args for repeated cycle modes and unknown tokens ([#157](https://github.com/raulgg/pods-control/issues/157)) ([1481f81](https://github.com/raulgg/pods-control/commit/1481f81380e9dc9e47302d4d7407bd7eb37ae3e4))


### Bug Fixes

* cycle listening modes in Apple's default order ([#152](https://github.com/raulgg/pods-control/issues/152)) ([4fcc89d](https://github.com/raulgg/pods-control/commit/4fcc89d046c12ba272b6484da4b0b11e1ef7ebd7))
* reject a repeated mode in cycle --modes ([#155](https://github.com/raulgg/pods-control/issues/155)) ([d2c7bb0](https://github.com/raulgg/pods-control/commit/d2c7bb0a697a4a7109eefa8856c8f0e2ecd923de))

## [0.5.0](https://github.com/raulgg/airpods-control/compare/v0.4.0...v0.5.0) (2026-10-01)


### ⚠ BREAKING CHANGES

* the command is now pods-control; airpods-control remains a symlink and Homebrew alias.

### Features

* rename the CLI binary to pods-control ([#145](https://github.com/raulgg/airpods-control/issues/145)) ([fdded22](https://github.com/raulgg/airpods-control/commit/fdded223a008282e8600571719936f2c60de081e))


### Bug Fixes

* restore listening mode after inferred Off fallback ([#143](https://github.com/raulgg/airpods-control/issues/143)) ([37ad499](https://github.com/raulgg/airpods-control/commit/37ad4990f6272e1d2e8b0eb152b3bdcd5fb06f2f))

## [0.4.0](https://github.com/raulgg/airpods-control/compare/v0.3.0...v0.4.0) (2026-09-05)


### Features

* **cli:** consolidate result and exit-code semantics ([#61](https://github.com/raulgg/airpods-control/issues/61)) ([ce98226](https://github.com/raulgg/airpods-control/commit/ce982265df7f826898e01d6c0daa953454d1cdb3))
* **status:** report AirPods ear placement ([#58](https://github.com/raulgg/airpods-control/issues/58)) ([4159037](https://github.com/raulgg/airpods-control/commit/4159037e46955989f89a4317e264046c82051b13))


### Bug Fixes

* **cli:** preserve discovery failures and denial TTL ([#68](https://github.com/raulgg/airpods-control/issues/68)) ([4a80204](https://github.com/raulgg/airpods-control/commit/4a80204fb66645b69cf961d93d3a5d86ff84d486))
* probe support-report listening modes Off last ([#91](https://github.com/raulgg/airpods-control/issues/91)) ([95c17ab](https://github.com/raulgg/airpods-control/commit/95c17ab1e2cc1e4dc3cbf4faf6d4b524f3af9add))


### Performance Improvements

* **cli:** defer HAL inventory until AV cannot serve ([#97](https://github.com/raulgg/airpods-control/issues/97)) ([762ffb8](https://github.com/raulgg/airpods-control/commit/762ffb8031cb2ae1071e7fd0de22e806493085f1))

## [0.3.0](https://github.com/raulgg/airpods-control/compare/v0.2.1...v0.3.0) (2026-08-27)


### Features

* control listening modes on unselected AirPods ([#31](https://github.com/raulgg/airpods-control/issues/31)) ([79cbd3a](https://github.com/raulgg/airpods-control/commit/79cbd3a3e8d2ed3b7d5defc5db45e1021d2ea0ff))
* verify AirPods Pro 2 (Lightning) compatibility ([#39](https://github.com/raulgg/airpods-control/issues/39)) ([d0e0358](https://github.com/raulgg/airpods-control/commit/d0e0358a71ceb5db3e3538d339535bd886094bac)), closes [#34](https://github.com/raulgg/airpods-control/issues/34)


### Bug Fixes

* clear stale Allow Off cache after a no-op ([#48](https://github.com/raulgg/airpods-control/issues/48)) ([8673a71](https://github.com/raulgg/airpods-control/commit/8673a7149e001942be7e4e1d4145cd491087f0d2))
* make Allow Off cache safe across stale reads ([#32](https://github.com/raulgg/airpods-control/issues/32)) ([9bd42d8](https://github.com/raulgg/airpods-control/commit/9bd42d8741620afcb6b14eb136d56ad0eb4ff246))

## Changelog

Release Please maintains this file from Conventional Commit titles merged after
`v0.2.1`. Earlier release notes remain available on the
[GitHub Releases](https://github.com/raulgg/airpods-control/releases) page.
