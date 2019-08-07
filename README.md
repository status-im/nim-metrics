# nim-metrics

[![Build Status (Travis)](https://img.shields.io/travis/status-im/nim-metrics/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nim-metrics)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/nimbus/nim-metrics/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/nimbus/nim-metrics)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

## Introduction

Nim metrics client library supporting the [Prometheus](https://prometheus.io/) monitoring toolkit.

## Installation

You can install the developement version of the library through Nimble with the following command
```
nimble install https://github.com/status-im/nim-metrics@#master
```

## Usage

To enable metrics, compile your code with `-d:metrics`. You also need `--threads:on` for atomic operations to work.

## Contributing

When submitting pull requests, please add test cases for any new features or fixes and make sure `nimble test` is still able to execute the entire test suite successfully.

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
* Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.

