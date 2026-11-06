//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftPrometheus open source project
//
// Copyright (c) 2018-2026 SwiftPrometheus project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftPrometheus project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Configuration
import XCTest

@testable import Prometheus

@available(macOS 15, iOS 18, watchOS 11, tvOS 18, visionOS 2, *)
final class PrometheusMetricsFactoryConfigurationTests: XCTestCase {
    private static let defaultBucketsVariable = "SWIFT_PROMETHEUS_DEFAULT_HISTOGRAM_BUCKETS"
    private static let durationBucketsVariable = "SWIFT_PROMETHEUS_DEFAULT_DURATION_HISTOGRAM_BUCKETS"
    private static let valueBucketsVariable = "SWIFT_PROMETHEUS_DEFAULT_VALUE_HISTOGRAM_BUCKETS"

    private func makeFactory(_ environment: [String: String] = [:]) async throws -> PrometheusMetricsFactory {
        try await PrometheusMetricsFactory(
            registry: PrometheusCollectorRegistry(),
            configuration: ConfigReader(provider: EnvironmentVariablesProvider(environmentVariables: environment))
        )
    }

    func testExistingInitializerUsesBuiltInDefaults() {
        let factory = PrometheusMetricsFactory(registry: PrometheusCollectorRegistry())
        XCTAssertEqual(
            factory.defaultDurationHistogramBuckets,
            PrometheusMetricsFactory.builtInDurationHistogramBuckets
        )
        XCTAssertEqual(factory.defaultValueHistogramBuckets, PrometheusMetricsFactory.builtInValueHistogramBuckets)
    }

    func testInMemoryConfigurationAndProviderPrecedence() async throws {
        let configuration = ConfigReader(providers: [
            InMemoryProvider(values: ["swift.prometheus.default.histogram.buckets": "0.5,1,5"]),
            EnvironmentVariablesProvider(environmentVariables: [Self.defaultBucketsVariable: "10,20"]),
        ])
        let factory = try await PrometheusMetricsFactory(configuration: configuration)
        XCTAssertEqual(factory.defaultDurationHistogramBuckets, [.milliseconds(500), .seconds(1), .seconds(5)])
        XCTAssertEqual(factory.defaultValueHistogramBuckets, [0.5, 1, 5])
    }

    func testInitRejectsWrongTypeSpecificValue() async {
        let configuration = ConfigReader(
            provider: InMemoryProvider(values: [
                "swift.prometheus.default.histogram.buckets": "1,2,3",
                "swift.prometheus.default.value.histogram.buckets": true,
            ])
        )
        do {
            _ = try await PrometheusMetricsFactory(configuration: configuration)
            XCTFail("Expected the non-string value to throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("swift.prometheus.default.value.histogram.buckets"))
        }
    }

    func testExplicitDefaultsAndPerLabelBucketsOverrideConfiguration() async throws {
        let registry = PrometheusCollectorRegistry()
        var factory = try await PrometheusMetricsFactory(
            registry: registry,
            configuration: ConfigReader(
                provider: InMemoryProvider(values: [
                    "swift.prometheus.default.histogram.buckets": "1,2,3"
                ])
            )
        )
        factory.defaultDurationHistogramBuckets = [.seconds(10)]
        factory.defaultValueHistogramBuckets = [20]
        factory.durationHistogramBuckets["custom_timer"] = [.seconds(30)]
        factory.valueHistogramBuckets["custom_value"] = [40]
        factory.makeTimer(label: "default_timer", dimensions: []).recordNanoseconds(1)
        factory.makeTimer(label: "custom_timer", dimensions: []).recordNanoseconds(1)
        factory.makeRecorder(label: "default_value", dimensions: [], aggregate: true).record(Int64(1))
        factory.makeRecorder(label: "custom_value", dimensions: [], aggregate: true).record(Int64(1))
        let output = registry.emitToString()
        XCTAssertTrue(output.contains(#"default_timer_bucket{le="10.0"} 1"#))
        XCTAssertTrue(output.contains(#"custom_timer_bucket{le="30.0"} 1"#))
        XCTAssertTrue(output.contains(#"default_value_bucket{le="20.0"} 1"#))
        XCTAssertTrue(output.contains(#"custom_value_bucket{le="40.0"} 1"#))
    }

    func testParseValueHistogramBuckets() {
        XCTAssertEqual(
            PrometheusMetricsFactory.parseValueHistogramBuckets("0.1,0.2,0.5,.75,0.9"),
            [0.1, 0.2, 0.5, 0.75, 0.9]
        )
        XCTAssertEqual(PrometheusMetricsFactory.parseValueHistogramBuckets("1"), [1])
        XCTAssertEqual(PrometheusMetricsFactory.parseValueHistogramBuckets(" 5,\t10 , 25 "), [5, 10, 25])
        XCTAssertEqual(PrometheusMetricsFactory.parseValueHistogramBuckets("1e-3,1e3"), [0.001, 1000])
        XCTAssertEqual(PrometheusMetricsFactory.parseValueHistogramBuckets("-10,-5,0,5"), [-10, -5, 0, 5])
    }

    func testParseValueHistogramBucketsRejectsMalformedInput() {
        for input in ["", " ", ",", ",1", "1,", "1,,2", "0.1;0.2", "0.1,foo", "0.1,inf", "0.1,nan"] {
            XCTAssertNil(PrometheusMetricsFactory.parseValueHistogramBuckets(input))
        }

        for input in ["1,1", "2,1"] {
            XCTAssertNil(PrometheusMetricsFactory.parseValueHistogramBuckets(input))
        }
    }

    func testParseDurationHistogramBuckets() {
        XCTAssertEqual(
            PrometheusMetricsFactory.parseDurationHistogramBuckets("0.1,0.2,0.5,.75,0.9"),
            [
                .milliseconds(100),
                .milliseconds(200),
                .milliseconds(500),
                .milliseconds(750),
                .milliseconds(900),
            ]
        )
        XCTAssertEqual(
            PrometheusMetricsFactory.parseDurationHistogramBuckets("0,1,60"),
            [.seconds(0), .seconds(1), .seconds(60)]
        )
    }

    func testParseDurationHistogramBucketsRejectsNegativeAndUnrepresentableValues() {
        XCTAssertNil(PrometheusMetricsFactory.parseDurationHistogramBuckets("-1,1"))
        // 1e300 seconds is finite but not representable as a `Duration`.
        XCTAssertNil(PrometheusMetricsFactory.parseDurationHistogramBuckets("1,1e300"))
        XCTAssertNotNil(PrometheusMetricsFactory.parseValueHistogramBuckets("1,1e300"))
    }

    func testInitReadsDefaultBucketsFromEnvironment() async throws {
        let factory = try await self.makeFactory([Self.defaultBucketsVariable: "0.5,1,5"])

        XCTAssertEqual(factory.defaultDurationHistogramBuckets, [.milliseconds(500), .seconds(1), .seconds(5)])
        XCTAssertEqual(factory.defaultValueHistogramBuckets, [0.5, 1, 5])
    }

    func testInitReadsSpecificBucketsFromEnvironment() async throws {
        let factory = try await self.makeFactory([
            Self.durationBucketsVariable: "0.5,1,5",
            Self.valueBucketsVariable: "10,100,1000",
        ])

        XCTAssertEqual(factory.defaultDurationHistogramBuckets, [.milliseconds(500), .seconds(1), .seconds(5)])
        XCTAssertEqual(factory.defaultValueHistogramBuckets, [10, 100, 1000])
    }

    func testSpecificBucketsTakePrecedenceOverDefaultBucketsEnvironment() async throws {
        let factory = try await self.makeFactory([
            Self.defaultBucketsVariable: "0.5,1,5",
            Self.durationBucketsVariable: "10,20,30",
            Self.valueBucketsVariable: "100,200,300",
        ])

        XCTAssertEqual(factory.defaultDurationHistogramBuckets, [.seconds(10), .seconds(20), .seconds(30)])
        XCTAssertEqual(factory.defaultValueHistogramBuckets, [100, 200, 300])
    }

    func testInitRejectsInvalidBucketLists() async {
        let cases = [
            (
                [Self.defaultBucketsVariable: "0.5,0.1,oops"],
                "swift.prometheus.default.histogram.buckets",
                "strictly increasing"
            ),
            (
                [Self.defaultBucketsVariable: "0.5,1,5", Self.durationBucketsVariable: "oops"],
                "swift.prometheus.default.duration.histogram.buckets",
                "representable as Duration"
            ),
            (
                [Self.defaultBucketsVariable: "0.5,1,5", Self.valueBucketsVariable: "1,,2"],
                "swift.prometheus.default.value.histogram.buckets",
                "strictly increasing"
            ),
            (
                [Self.defaultBucketsVariable: "-5,0,5"],
                "swift.prometheus.default.histogram.buckets",
                "nonnegative"
            ),
        ]
        for (environment, key, requirement) in cases {
            do {
                _ = try await self.makeFactory(environment)
                XCTFail("Expected invalid buckets for \(key) to throw")
            } catch {
                let message = String(describing: error)
                XCTAssertTrue(message.contains(key), message)
                XCTAssertTrue(message.contains(requirement), message)
            }
        }
    }

    func testSharedBucketsCanBeNegativeWithDurationOverride() async throws {
        let factory = try await self.makeFactory([
            Self.defaultBucketsVariable: "-5,0,5",
            Self.durationBucketsVariable: "1,5",
        ])

        XCTAssertEqual(factory.defaultDurationHistogramBuckets, [.seconds(1), .seconds(5)])
        XCTAssertEqual(factory.defaultValueHistogramBuckets, [-5, 0, 5])
    }

    func testInitUsesBuiltInBucketsIfEnvironmentIsUnset() async throws {
        let factory = try await self.makeFactory()

        XCTAssertEqual(
            factory.defaultDurationHistogramBuckets,
            PrometheusMetricsFactory.builtInDurationHistogramBuckets
        )
        XCTAssertEqual(factory.defaultValueHistogramBuckets, PrometheusMetricsFactory.builtInValueHistogramBuckets)
    }

    func testTimerUsesDurationBucketsFromEnvironment() async throws {
        let registry = PrometheusCollectorRegistry()
        let factory = try await PrometheusMetricsFactory(
            registry: registry,
            configuration: ConfigReader(
                provider: EnvironmentVariablesProvider(
                    environmentVariables: [Self.defaultBucketsVariable: "0.1,0.2,0.5,.75,0.9"]
                )
            )
        )

        let timer = factory.makeTimer(label: "request_duration_seconds", dimensions: [])
        timer.recordNanoseconds(300_000_000)  // 300ms

        let output = registry.emitToString()
        XCTAssertTrue(output.contains(#"request_duration_seconds_bucket{le="0.5"} 1"#))
        XCTAssertTrue(output.contains(#"request_duration_seconds_sum 0.3"#))
    }

    func testExplicitlyConfiguredBucketsTakePrecedenceOverEnvironment() async throws {
        let registry = PrometheusCollectorRegistry()
        var factory = try await PrometheusMetricsFactory(
            registry: registry,
            configuration: ConfigReader(
                provider: EnvironmentVariablesProvider(
                    environmentVariables: [Self.defaultBucketsVariable: "1,2,3"]
                )
            )
        )
        factory.durationHistogramBuckets["explicitly_configured"] = [.seconds(10)]

        XCTAssertEqual(factory.defaultDurationHistogramBuckets, [.seconds(1), .seconds(2), .seconds(3)])

        let timer = factory.makeTimer(label: "explicitly_configured", dimensions: [])
        timer.recordNanoseconds(1)

        XCTAssertTrue(registry.emitToString().contains(#"explicitly_configured_bucket{le="10.0"} 1"#))
    }
}
