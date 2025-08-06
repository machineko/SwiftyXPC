//
//  TestHelper.swift
//
//
//  Created by Charles Srstka on 10/12/23.
//

import Foundation
import Dispatch
import SwiftyXPC
import TestShared
import IOSurface
import Metal

@preconcurrency class HelperLogger {
    private let fileHandle: FileHandle
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.example.helperlogger")

    static let shared = try! HelperLogger()

    init() throws {
        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("helper-debug.log").path

        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        self.fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))

        self.fileHandle.seekToEndOfFile()

        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let message = "Helper logger initialized. Log file: \(logPath)\n"
        if let data = message.data(using: .utf8) {
            self.fileHandle.write(data)
        }
    }

    deinit {
        try? self.fileHandle.close()
    }

    func log(_ message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            let logMessage = "[\(timestamp)] \(message)\n"

            if let data = logMessage.data(using: .utf8) {
                self.fileHandle.write(data)
            }
        }
    }
}


@main
@available(macOS 13.0, *)
final class XPCService: Sendable {
    static func main() {
        do {
            let xpcService = XPCService()

            let listener = try XPCListener(type: .machService(name: helperID), codeSigningRequirement: nil)

            listener.setMessageHandler(name: CommandSet.reportIDs, handler: xpcService.reportIDs)
            listener.setMessageHandler(name: CommandSet.capitalizeString, handler: xpcService.capitalizeString)
            listener.setMessageHandler(name: CommandSet.multiplyBy5, handler: xpcService.multiplyBy5)
            listener.setMessageHandler(name: CommandSet.transportData, handler: xpcService.transportData)
            listener.setMessageHandler(name: CommandSet.tellAJoke, handler: xpcService.tellAJoke)
            listener.setMessageHandler(name: CommandSet.pauseOneSecond, handler: xpcService.pauseOneSecond)
            listener.setMessageHandler(name: CommandSet.ioSurfaceTestCodable, handler: xpcService.ioSurfaceTestCodable)

            listener.setRawMessageHandler(name: CommandSet.rawDictionaryTest) { _, dictionary in
                let dictionary = xpc_dictionary_get_value(dictionary, "com.charlessoft.SwiftyXPC.XPCEventHandler.Body")!

                let logger = HelperLogger.shared

                logger.log("Raw message handler called for 'rawDictionaryTest'")

                logger.log("Incoming dictionary type: \(xpc_get_type(dictionary))")
                logger.log("Incoming dictionary count: \(xpc_dictionary_get_count(dictionary))")

                logger.log("Enumerating dictionary keys:")
                xpc_dictionary_apply(dictionary, { key, value in
                    let keyString = String(cString: key)
                    logger.log("Found key '\(keyString)' with type \(xpc_get_type(value))")
                    return true
                })

                let response = xpc_dictionary_create(nil, nil, 0)
                logger.log("Created response dictionary")

                if let numberValue = xpc_dictionary_get_value(dictionary, "number") {
                    logger.log("Found 'number' key with type \(xpc_get_type(numberValue))")

                    let number = xpc_int64_get_value(numberValue)
                    logger.log("Extracted number value: \(number)")

                    let doubledNumber = number * 2
                    logger.log("Calculated doubledNumber: \(doubledNumber)")

                    xpc_dictionary_set_int64(response, "doubledNumber", doubledNumber)
                    logger.log("Set 'doubledNumber' in response")
                } else {
                    logger.log("ERROR - Could not find 'number' key in dictionary")
                    xpc_dictionary_set_int64(response, "doubledNumber", 0)
                }

                if let textValue = xpc_dictionary_get_value(dictionary, "text") {
                    logger.log("Found 'text' key with type \(xpc_get_type(textValue))")

                    if let textPtr = xpc_string_get_string_ptr(textValue) {
                        let text = String(cString: textPtr)
                        logger.log("Extracted text value: '\(text)'")

                        let uppercasedText = text.uppercased()
                        logger.log("Calculated uppercasedText: '\(uppercasedText)'")

                        xpc_dictionary_set_string(response, "uppercasedText", uppercasedText)
                        logger.log("Set 'uppercasedText' in response")
                    } else {
                        logger.log("ERROR - Could not get string pointer from text value")
                    }
                } else {
                    logger.log("ERROR - Could not find 'text' key in dictionary")
                }

                let currentTime = Date().timeIntervalSince1970
                xpc_dictionary_set_date(response, "timestamp", Int64(currentTime))
                logger.log("Set 'timestamp' in response: \(Date(timeIntervalSince1970: currentTime))")

                logger.log("Final response dictionary count: \(xpc_dictionary_get_count(response))")
                logger.log("Enumerating response keys:")
                xpc_dictionary_apply(response, { key, value in
                    let keyString = String(cString: key)
                    logger.log("Response key '\(keyString)' with type \(xpc_get_type(value))")

                    if keyString == "doubledNumber" {
                        let doubledNumber = xpc_int64_get_value(value)
                        logger.log("Response 'doubledNumber' value: \(doubledNumber)")
                    } else if keyString == "uppercasedText" {
                        if let textPtr = xpc_string_get_string_ptr(value) {
                            logger.log("Response 'uppercasedText' value: '\(String(cString: textPtr))'")
                        }
                    } else if keyString == "timestamp" {
                        let timestamp = xpc_date_get_value(value)
                        logger.log("Response 'timestamp' value: \(Date(timeIntervalSince1970: TimeInterval(timestamp)))")
                    }

                    return true
                })

                logger.log("Returning response dictionary")
                return response
            }
            
            listener.setMessageHandlerRaw(name: CommandSet.ioSurfaceTest, handler: xpcService.createIOSurfaceBufferMixed)


            listener.activate()
            dispatchMain()
        } catch {
            fatalError("Error while setting up XPC service: \(error)")
        }
    }
    
    struct IOSurfaceResponse: Codable {
        @IOSurfaceForXPC var surface: IOSurfaceRef
        let status: Int
        let message: String

        init(surfaceRef: IOSurfaceRef, status: Int = 200, message: String = "Success") {
            // Convert IOSurfaceRef to IOSurface
            self._surface = IOSurfaceForXPC(wrappedValue: unsafeBitCast(surfaceRef, to: IOSurface.self))
            self.status = status
            self.message = message
        }
    }

    
    private func ioSurfaceTestCodable(_: XPCConnection, request: IOSurfaceMessage) async throws -> IOSurfaceResponse {
        let surfaceSize = Int(request.size)
        let aData: [Float32] = Array(repeating: 2.0, count: surfaceSize)
        let device = MTLCreateSystemDefaultDevice()!
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: surfaceSize * MemoryLayout<Float32>.stride,
            .bytesPerRow: surfaceSize * MemoryLayout<Float32>.stride,
            .allocSize: surfaceSize * MemoryLayout<Float32>.stride,
            .height: 1
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            fatalError("Cannot create IOSurface")
        }

        let tmpBuff = device.makeBuffer(bytesNoCopy: IOSurfaceGetBaseAddress(surface),
                             length: aData.count * MemoryLayout<Float32>.stride,
                              options: .storageModeShared,
                             deallocator: nil)
        
        IOSurfaceLock(surface, [], nil)
        memcpy(tmpBuff?.contents(), aData, aData.count * MemoryLayout<Float32>.stride)
        IOSurfaceUnlock(surface, [], nil)
        
        return IOSurfaceResponse(surfaceRef: surface)

    }

    private func createIOSurfaceBufferMixed(_: XPCConnection, request: IOSurfaceMessage) async throws -> xpc_object_t {
        let surfaceSize = Int(request.size)
        let aData: [Float32] = Array(repeating: 2.0, count: surfaceSize)
        let device = MTLCreateSystemDefaultDevice()!
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: surfaceSize * MemoryLayout<Float32>.stride,
            .bytesPerRow: surfaceSize * MemoryLayout<Float32>.stride,
            .allocSize: surfaceSize * MemoryLayout<Float32>.stride,
            .height: 1
        ]

        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            fatalError("Cannot create IOSurface")
        }

        let tmpBuff = device.makeBuffer(bytesNoCopy: IOSurfaceGetBaseAddress(surface),
                             length: aData.count * MemoryLayout<Float32>.stride,
                              options: .storageModeShared,
                             deallocator: nil)
        IOSurfaceLock(surface, [], nil)
        memcpy(tmpBuff?.contents(), aData, aData.count * MemoryLayout<Float32>.stride)
        IOSurfaceUnlock(surface, [], nil)
        let xpcObj = IOSurfaceCreateXPCObject(surface)
        let rawResponse = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(rawResponse, "iosurface", xpcObj)
        return rawResponse
    }

    
    private func reportIDs(connection: XPCConnection) async throws -> ProcessIDs {
        try ProcessIDs(connection: connection)
    }

    private func capitalizeString(_: XPCConnection, string: String) async throws -> String {
        string.uppercased()
    }

    private func multiplyBy5(_: XPCConnection, number: Double) async throws -> Double {
        number * 5.0
    }

    private func transportData(_: XPCConnection, data: Data) async throws -> DataInfo {
        guard String(data: data, encoding: .utf8) == "One to beam up" else {
            throw DataInfo.DataError(failureReason: "fluctuation in the positronic matrix")
        }

        return DataInfo(
            characterName: "Lt. Cmdr. Data".data(using: .utf8)!,
            playedBy: "Brent Spiner".data(using: .utf8)!,
            otherCharacters: [
                "Lore".data(using: .utf8)!,
                "B4".data(using: .utf8)!,
                "Noonien Soong".data(using: .utf8)!,
                "Arik Soong".data(using: .utf8)!,
                "Altan Soong".data(using: .utf8)!,
                "Adam Soong".data(using: .utf8)!
            ]
        )
    }

    private func tellAJoke(_: XPCConnection, endpoint: SwiftyXPC.XPCEndpoint) async throws {
        let remoteConnection = try XPCConnection(
            type: .remoteServiceFromEndpoint(endpoint),
            codeSigningRequirement: nil
        )

        remoteConnection.activate()

        let opening: String = try await remoteConnection.sendMessage(name: JokeMessage.askForJoke, request: "Tell me a joke")

        guard opening == "Knock knock" else {
            throw JokeMessage.NotAKnockKnockJoke(complaint: "That was not a knock knock joke!")
        }

        let whosThere: String = try await remoteConnection.sendMessage(name: JokeMessage.whosThere, request: "Who's there?")

        try await remoteConnection.sendMessage(name: JokeMessage.who, request: "\(whosThere) who?")

        try remoteConnection.sendOnewayMessage(name: JokeMessage.groan, message: "That was awful!")
    }

    private func pauseOneSecond(_: XPCConnection) async throws {
        try await Task.sleep(for: .seconds(1))
    }
}
