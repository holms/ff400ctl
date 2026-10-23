import Foundation
import IOKit

/// Minimal client for ASFW's `ASFWDriverUserClient` DriverKit user client.
///
/// Opens every `ASFWDriver` service (there may be several FireWire
/// controllers), performs the status-listener handshake the app uses,
/// and issues raw async quadlet/block transactions.
///
/// Requires the `com.apple.developer.driverkit.userclient-access`
/// entitlement containing `net.asfw.driver` (ad-hoc signing works).
public final class ASFWClient {

    public enum Method: UInt32 {
        case asyncRead            = 8
        case asyncWrite           = 9
        case registerStatusListener = 10
        case getTransactionResult = 12
        case asyncBlockRead       = 44
        case asyncBlockWrite      = 45
    }

    public struct TransactionResult {
        public let status: UInt64
        public let responseCode: UInt64
        public let data: Data
    }

    public enum ClientError: Error {
        case noServices
        case notConnected
        case callFailed(kern_return_t)
        case timeout
    }

    /// One entry per successfully opened ASFWDriver service.
    private var connections: [io_connect_t] = []
    /// Status-listener mach ports created by `handshake`, per connection.
    private var listenerPorts: [mach_port_t] = []
    /// Shared-memory mappings created by `handshake`, per connection.
    private var mappings: [(conn: io_connect_t, addr: mach_vm_address_t)] = []

    public var connectionCount: Int { connections.count }

    public init() throws {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceNameMatching("ASFWDriver") as CFDictionary,
            &iter) == KERN_SUCCESS
        else { throw ClientError.noServices }

        while case let service = IOIteratorNext(iter), service != 0 {
            var conn: io_connect_t = 0
            if IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS {
                connections.append(conn)
                handshake(conn)
            }
            IOObjectRelease(service)
        }
        guard !connections.isEmpty else { throw ClientError.notConnected }
    }

    deinit {
        for m in mappings {
            _ = IOConnectUnmapMemory64(m.conn, 0, mach_task_self_, m.addr)
        }
        for port in listenerPorts {
            mach_port_mod_refs(mach_task_self_, port,
                               mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
        }
        for conn in connections { IOServiceClose(conn) }
    }

    /// Replicates the ASFW app's open sequence: map shared memory (type 0)
    /// then register a status listener on a mach port (selector 10).
    private func handshake(_ conn: io_connect_t) {
        var addr: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        if IOConnectMapMemory64(conn, 0, mach_task_self_, &addr, &size,
                                UInt32(kIOMapAnywhere | kIOMapDefaultCache)) == KERN_SUCCESS,
           addr != 0 {
            mappings.append((conn, addr))
        }

        var port: mach_port_t = 0
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
                == KERN_SUCCESS else { return }
        listenerPorts.append(port)
        mach_port_insert_right(mach_task_self_, port, port,
                               mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        var ref: UInt64 = 0
        var outCount: UInt32 = 0
        var outScalars = [UInt64](repeating: 0, count: 8)
        outScalars.withUnsafeMutableBufferPointer { buf in
            _ = IOConnectCallAsyncScalarMethod(conn, Method.registerStatusListener.rawValue,
                                               port, &ref, 1, nil, 0, buf.baseAddress, &outCount)
        }
    }

    /// Issue an async write. Returns one transaction handle per connection;
    /// the key is the connection index.
    @discardableResult
    public func asyncWrite(destinationID: UInt16, addressHigh: UInt16,
                           addressLow: UInt32, payload: Data) -> [Int: UInt16] {
        rawWrite(selector: Method.asyncWrite, destinationID: destinationID,
                 addressHigh: addressHigh, addressLow: addressLow, payload: payload)
    }

    /// Issue an async *block* write (selector 45) — one transaction carrying
    /// more than 4 bytes, e.g. the FF400's 3-quadlet config block.
    @discardableResult
    public func asyncBlockWrite(destinationID: UInt16, addressHigh: UInt16,
                                addressLow: UInt32, payload: Data) -> [Int: UInt16] {
        rawWrite(selector: Method.asyncBlockWrite, destinationID: destinationID,
                 addressHigh: addressHigh, addressLow: addressLow, payload: payload)
    }

    /// Issue an async *block* read (selector 44) — one transaction fetching
    /// `length` bytes, e.g. the FF400's 648-byte meter block.
    @discardableResult
    public func asyncBlockRead(destinationID: UInt16, addressHigh: UInt16,
                               addressLow: UInt32, length: UInt32) -> [Int: UInt16] {
        var scalars: [UInt64] = [UInt64(destinationID), UInt64(addressHigh),
                                 UInt64(addressLow), UInt64(length)]
        var handles: [Int: UInt16] = [:]
        for (i, conn) in connections.enumerated() {
            var out: UInt64 = 0
            var outCount: UInt32 = 1
            let kr = scalars.withUnsafeMutableBufferPointer { s in
                IOConnectCallMethod(conn, Method.asyncBlockRead.rawValue,
                                    s.baseAddress, 4, nil, 0,
                                    &out, &outCount, nil, nil)
            }
            if kr == KERN_SUCCESS { handles[i] = UInt16(truncatingIfNeeded: out) }
        }
        return handles
    }

    private func rawWrite(selector: Method, destinationID: UInt16, addressHigh: UInt16,
                          addressLow: UInt32, payload: Data) -> [Int: UInt16] {
        var scalars: [UInt64] = [UInt64(destinationID), UInt64(addressHigh),
                                 UInt64(addressLow), UInt64(payload.count)]
        var handles: [Int: UInt16] = [:]
        for (i, conn) in connections.enumerated() {
            var out: UInt64 = 0
            var outCount: UInt32 = 1
            let kr = payload.withUnsafeBytes { p in
                scalars.withUnsafeMutableBufferPointer { s in
                    IOConnectCallMethod(conn, selector.rawValue,
                                        s.baseAddress, 4,
                                        p.baseAddress, p.count,
                                        &out, &outCount, nil, nil)
                }
            }
            if kr == KERN_SUCCESS { handles[i] = UInt16(truncatingIfNeeded: out) }
        }
        return handles
    }

    /// Fetch a completed transaction's result (selector 12).
    public func getTransactionResult(handle: UInt16, onConnection index: Int) -> TransactionResult? {
        guard connections.indices.contains(index) else { return nil }
        var scalarIn: [UInt64] = [UInt64(handle)]
        var scalarOut: [UInt64] = [0, 0, 0]
        var scalarOutCount: UInt32 = 3
        var payload = Data(count: 2048)
        var payloadSize = payload.count
        let kr = payload.withUnsafeMutableBytes { p in
            scalarIn.withUnsafeMutableBufferPointer { si in
                scalarOut.withUnsafeMutableBufferPointer { so in
                    IOConnectCallMethod(connections[index], Method.getTransactionResult.rawValue,
                                        si.baseAddress, 1, nil, 0,
                                        so.baseAddress, &scalarOutCount,
                                        p.baseAddress, &payloadSize)
                }
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return TransactionResult(status: scalarOut[0], responseCode: scalarOut[2],
                                 data: Data(payload.prefix(payloadSize)))
    }

    /// Poll a handle until its result is stored or `timeoutMs` elapses.
    public func awaitResult(handle: UInt16, onConnection index: Int,
                            timeoutMs: Int = 1000) -> TransactionResult? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let r = getTransactionResult(handle: handle, onConnection: index) { return r }
            usleep(5_000)
        }
        return nil
    }

    /// Convenience: write a little-endian quadlet to a node register and
    /// return true if it completed on at least one connection.
    @discardableResult
    public func writeQuadlet(node: UInt16 = 0xffc0, address: UInt32,
                             value: UInt32, verify: Bool = true) -> Bool {
        let handles = asyncWrite(destinationID: node, addressHigh: 0,
                                 addressLow: address, payload: Fireface400.payload(for: value))
        return verifyHandles(handles, verify: verify)
    }

    /// Convenience: write a multi-quadlet block to a node register
    /// (e.g. the 3-quadlet config block at 0x80100514).
    @discardableResult
    public func writeBlock(node: UInt16 = 0xffc0, address: UInt32,
                           payload: Data, verify: Bool = true) -> Bool {
        let handles = asyncBlockWrite(destinationID: node, addressHigh: 0,
                                      addressLow: address, payload: payload)
        return verifyHandles(handles, verify: verify)
    }

    private func verifyHandles(_ handles: [Int: UInt16], verify: Bool) -> Bool {
        guard !handles.isEmpty else { return false }
        if !verify { return true }
        for (conn, handle) in handles {
            if let r = awaitResult(handle: handle, onConnection: conn), r.status == 0 {
                return true
            }
        }
        return false
    }
}
