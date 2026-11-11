//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Configuration for an SSH client.
public struct SSHClientConfiguration {
    /// The user authentication delegate to be used with this client.
    public var userAuthDelegate: NIOSSHClientUserAuthenticationDelegate

    /// The server authentication delegate to be used with this client.
    public var serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate

    /// The global request delegate to be used with this client.
    public var globalRequestDelegate: GlobalRequestDelegate

    /// The enabled TransportProtectionSchemes
    public var transportProtectionSchemes: [NIOSSHTransportProtection.Type] = SSHConnectionStateMachine.bundledTransportProtectionSchemes

    /// The enabled KeyExchangeAlgorithms
    public var keyExchangeAlgorithms: [NIOSSHKeyExchangeAlgorithmProtocol.Type] = SSHKeyExchangeStateMachine.bundledKeyExchangeImplementations

    /// RELAY PATCH: host key algorithms to ask for first, most wanted
    /// first (the ones the client already holds a key of, for this host, as
    /// OpenSSH orders HostKeyAlgorithms). A server with several host keys
    /// then presents one the client can check, rather than one it has
    /// never seen. Names this build doesn't support are ignored.
    public var preferredServerHostKeyAlgorithms: [String] = []

    /// The maximum packet size that this NIOSSH client will accept
    public var maximumPacketSize = SSHPacketParser.defaultMaximumPacketSize

    public init(userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
                serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate,
                globalRequestDelegate: GlobalRequestDelegate? = nil)
    {
        self.userAuthDelegate = userAuthDelegate
        self.serverAuthDelegate = serverAuthDelegate
        self.globalRequestDelegate = globalRequestDelegate ?? DefaultGlobalRequestDelegate()
    }
}
