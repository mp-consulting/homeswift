import Foundation
import Matter

/// What a node is made of (Core §9.5 Descriptor, §11.1 Basic Information): who it is, and its endpoints with their
/// device types and server clusters. Read once a session is up; enough to build its accessories.
struct NodeStructure: Codable, Sendable, Equatable {
    struct Endpoint: Codable, Sendable, Equatable {
        var id: EndpointNumber
        var deviceTypes: [UInt32]
        var clusters: [ClusterID]
        var parts: [EndpointNumber]
        /// A bridged device's name (Bridged Device Basic Information's NodeLabel).
        var label: String?
        /// The Switch cluster's FeatureMap and MultiPressMax, for a switch endpoint.
        var switchFeatures: UInt32?
        var multiPressMax: Int?
        /// The Power Source cluster's FeatureMap: a battery only with BAT (Core §11.7.4).
        var powerFeatures: UInt32?

        func has(_ cluster: ClusterID) -> Bool { clusters.contains(cluster) }
        func `is`(_ type: DeviceType) -> Bool { deviceTypes.contains(type.id) }

        var switchFeatureSet: SwitchCluster.Feature { SwitchCluster.Feature(rawValue: switchFeatures ?? 0) }
        var hasBattery: Bool { has(PowerSourceCluster.id) && PowerSourceCluster.Feature(rawValue: powerFeatures ?? 0).contains(.battery) }
        /// A rotary part of a remote (BILRESA's wheel): it counts many presses per gesture and has no long press,
        /// where a button counts at most a triple press and holds.
        var isRotary: Bool {
            has(SwitchCluster.id) && (multiPressMax ?? 0) > 3 && !switchFeatureSet.contains(.momentarySwitchLongPress)
        }
    }

    var vendorName: String?
    var vendorID: UInt16?
    var productName: String?
    var productID: UInt16?
    var nodeLabel: String?
    var softwareVersion: String?
    var serialNumber: String?
    var uniqueID: String?
    var endpoints: [Endpoint]

    /// The name to show: its own label, else its product's, else its vendor's.
    var name: String {
        [nodeLabel, productName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? vendorName ?? "Matter device"
    }

    func endpoint(_ id: EndpointNumber) -> Endpoint? { endpoints.first { $0.id == id } }

    /// The endpoints with a Switch cluster, in order.
    var switches: [Endpoint] { endpoints.filter { $0.has(SwitchCluster.id) }.sorted { $0.id < $1.id } }

    /// What it reads for its structure: Basic Information on the root endpoint, every endpoint's Descriptor, the
    /// switches' features and bridged devices' names.
    static let paths: [AttributePath] = [
        BasicInformationCluster.Attribute.vendorName, BasicInformationCluster.Attribute.vendorId, BasicInformationCluster.Attribute.productName,
        BasicInformationCluster.Attribute.productId, BasicInformationCluster.Attribute.nodeLabel,
        BasicInformationCluster.Attribute.softwareVersionString, BasicInformationCluster.Attribute.serialNumber,
        BasicInformationCluster.Attribute.uniqueId,
    ].map { AttributePath(endpoint: 0, cluster: BasicInformationCluster.id, attribute: $0) } + [
        AttributePath(cluster: DescriptorCluster.id, attribute: DescriptorCluster.Attribute.deviceTypeList),
        AttributePath(cluster: DescriptorCluster.id, attribute: DescriptorCluster.Attribute.serverList),
        AttributePath(cluster: DescriptorCluster.id, attribute: DescriptorCluster.Attribute.partsList),
        AttributePath(cluster: SwitchCluster.id, attribute: SwitchCluster.Attribute.multiPressMax),
        AttributePath(cluster: SwitchCluster.id, attribute: 0xFFFC),
        AttributePath(cluster: PowerSourceCluster.id, attribute: 0xFFFC),
        AttributePath(cluster: BridgedDeviceBasicInformationCluster.id, attribute: BridgedDeviceBasicInformationCluster.Attribute.nodeLabel),
    ]

    /// The structure from what a read of `paths` answered. A list split across reports (ListIndex null, Core
    /// §10.6.4.3.1) is put back together; a value of the wrong type is left out rather than trusted.
    init(reports: [AttributeReport]) {
        let values = reports.values
        func text(_ attribute: AttributeID) -> String? {
            values[ConcreteAttribute(0, BasicInformationCluster.id, attribute)]?.string.flatMap { $0.isEmpty ? nil : $0 }
        }
        func number(_ attribute: AttributeID) -> UInt16? {
            values[ConcreteAttribute(0, BasicInformationCluster.id, attribute)]?.uint.flatMap { UInt16(exactly: $0) }
        }
        vendorName = text(BasicInformationCluster.Attribute.vendorName)
        vendorID = number(BasicInformationCluster.Attribute.vendorId)
        productName = text(BasicInformationCluster.Attribute.productName)
        productID = number(BasicInformationCluster.Attribute.productId)
        nodeLabel = text(BasicInformationCluster.Attribute.nodeLabel)
        softwareVersion = text(BasicInformationCluster.Attribute.softwareVersionString)
        serialNumber = text(BasicInformationCluster.Attribute.serialNumber)
        uniqueID = text(BasicInformationCluster.Attribute.uniqueId)

        let ids = Set(values.keys.filter { $0.cluster == DescriptorCluster.id }.map(\.endpoint))
        endpoints = ids.sorted().map { id in
            func value(_ cluster: ClusterID, _ attribute: AttributeID) -> TLVValue? {
                values[ConcreteAttribute(id, cluster, attribute)]
            }
            let types = (value(DescriptorCluster.id, DescriptorCluster.Attribute.deviceTypeList)?.elements ?? []).compactMap {
                $0.value[0]?.uint.flatMap { UInt32(exactly: $0) }
            }
            let clusters = (value(DescriptorCluster.id, DescriptorCluster.Attribute.serverList)?.elements ?? []).compactMap {
                $0.value.uint.flatMap { UInt32(exactly: $0) }
            }
            let parts = (value(DescriptorCluster.id, DescriptorCluster.Attribute.partsList)?.elements ?? []).compactMap {
                $0.value.uint.flatMap { UInt16(exactly: $0) }
            }
            return Endpoint(
                id: id, deviceTypes: types, clusters: clusters, parts: parts,
                label: value(BridgedDeviceBasicInformationCluster.id, BridgedDeviceBasicInformationCluster.Attribute.nodeLabel)?.string
                    .flatMap { $0.isEmpty ? nil : $0 },
                switchFeatures: value(SwitchCluster.id, 0xFFFC)?.uint.flatMap { UInt32(exactly: $0) },
                multiPressMax: value(SwitchCluster.id, SwitchCluster.Attribute.multiPressMax)?.uint.flatMap { Int(exactly: $0) },
                powerFeatures: value(PowerSourceCluster.id, 0xFFFC)?.uint.flatMap { UInt32(exactly: $0) })
        }
    }

    init(endpoints: [Endpoint], vendorName: String? = nil, productName: String? = nil) {
        self.endpoints = endpoints
        self.vendorName = vendorName
        self.productName = productName
    }
}

extension ConcreteAttribute {
    var path: AttributePath { AttributePath(endpoint: endpoint, cluster: cluster, attribute: attribute) }
}
