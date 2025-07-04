import XCTest

@testable import SwiftyXPC
import System
import TestShared

final class SwiftyXPCTests: XCTestCase {
    var helperLauncher: HelperLauncher?

    override func setUp() async throws {
        self.helperLauncher = try HelperLauncher()
        try self.helperLauncher?.startHelper()
    }

    override func tearDown() async throws {
        try self.helperLauncher?.stopHelper()
    }

    func testProcessIDs() async throws {
        let conn = try self.openConnection()

        let ids: ProcessIDs = try await conn.sendMessage(name: CommandSet.reportIDs)

        XCTAssertEqual(ids.pid, conn.processIdentifier)
        XCTAssertEqual(ids.effectiveUID, conn.effectiveUserIdentifier)
        XCTAssertEqual(ids.effectiveGID, conn.effectiveGroupIdentifier)
        XCTAssertEqual(ids.auditSessionID, conn.auditSessionIdentifier)
    }

    func testCodeSignatureVerification() async throws {
        let goodConn = try self.openConnection(codeSigningRequirement: self.helperLauncher!.codeSigningRequirement)

        let response: String = try await goodConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        XCTAssertEqual(response, "TESTING 1 2 3")

        let badConn = try self.openConnection(codeSigningRequirement: "identifier \"com.apple.true\" and anchor apple")
        let failsSignatureVerification = self.expectation(
            description: "Fails to send message because of code signature mismatch"
        )

        do {
            try await badConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        } catch let error as XPCError {
            if case .unknown(let errorDesc) = error, errorDesc == "Peer Forbidden" {
                failsSignatureVerification.fulfill()
            } else {
                throw error
            }
        }

        let failsConnectionInitialization = self.expectation(
            description: "Fails to initialize connection because of bad code signing requirement"
        )

        do {
            _ = try self.openConnection(codeSigningRequirement: "")
        } catch XPCError.invalidCodeSignatureRequirement {
            failsConnectionInitialization.fulfill()
        }

        await fulfillment(of: [failsSignatureVerification, failsConnectionInitialization], timeout: 10.0)
    }

    func testSimpleRequestAndResponse() async throws {
        let conn = try self.openConnection()

        let stringResponse: String = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "hi there")
        XCTAssertEqual(stringResponse, "HI THERE")

        let doubleResponse: Double = try await conn.sendMessage(name: CommandSet.multiplyBy5, request: 3.7)
        XCTAssertEqual(doubleResponse, 18.5, accuracy: 0.001)
    }

    func testDataTransport() async throws {
        let conn = try self.openConnection()

        let dataInfo: DataInfo = try await conn.sendMessage(
            name: CommandSet.transportData,
            request: "One to beam up".data(using: .utf8)!
        )

        XCTAssertEqual(String(data: dataInfo.characterName, encoding: .utf8), "Lt. Cmdr. Data")
        XCTAssertEqual(String(data: dataInfo.playedBy, encoding: .utf8), "Brent Spiner")
        XCTAssertEqual(
            dataInfo.otherCharacters.map { String(data: $0, encoding: .utf8) },
            ["Lore", "B4", "Noonien Soong", "Arik Soong", "Altan Soong", "Adam Soong"]
        )

        XPCErrorRegistry.shared.registerDomain(forErrorType: DataInfo.DataError.self)
        let failsToSendBadData = self.expectation(description: "Fails to send bad data")

        do {
            try await conn.sendMessage(name: CommandSet.transportData, request: "It's Lore being sneaky".data(using: .utf8)!)
        } catch let error as DataInfo.DataError {
            XCTAssertEqual(error.failureReason, "fluctuation in the positronic matrix")
            failsToSendBadData.fulfill()
        }

        await fulfillment(of: [failsToSendBadData], timeout: 10.0)
    }

    func testTwoWayCommunication() async throws {
        let conn = try self.openConnection()

        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)

        let asksForJoke = self.expectation(description: "We will get asked for a joke")
        let saysWhosThere = self.expectation(description: "The task will ask who's there")
        let asksWho = self.expectation(description: "The task will respond to our query and add 'who?'")
        let groans = self.expectation(description: "The task will not appreciate the joke")
        let expectations = [asksForJoke, saysWhosThere, asksWho, groans]
        expectations.forEach { $0.assertForOverFulfill = true }

        listener.setMessageHandler(name: JokeMessage.askForJoke) { _, response in
            XCTAssertEqual(response, "Tell me a joke")
            asksForJoke.fulfill()
            return "Knock knock"
        }

        listener.setMessageHandler(name: JokeMessage.whosThere) { _, response in
            XCTAssertEqual(response, "Who's there?")
            saysWhosThere.fulfill()
            return "Orange"
        }

        listener.setMessageHandler(name: JokeMessage.who) { _, response in
            XCTAssertEqual(response, "Orange who?")
            asksWho.fulfill()
            return "Orange you glad this example is so silly?"
        }

        listener.setMessageHandler(name: JokeMessage.groan) { _, response in
            XCTAssertEqual(response, "That was awful!")
            groans.fulfill()
        }

        listener.errorHandler = { _, error in
            if case .connectionInvalid = error as? XPCError {
                // connection can go down once we've received the last message
                return
            }

            DispatchQueue.main.async {
                XCTFail(error.localizedDescription)
            }
        }

        listener.activate()

        try await conn.sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)

        await self.fulfillment(of: expectations, timeout: 10.0, enforceOrder: true)
    }

    func testTwoWayCommunicationWithError() async throws {
        XPCErrorRegistry.shared.registerDomain(forErrorType: JokeMessage.NotAKnockKnockJoke.self)
        let conn = try self.openConnection()

        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)

        listener.setMessageHandler(name: JokeMessage.askForJoke) { _, response in
            XCTAssertEqual(response, "Tell me a joke")
            return "A `foo` walks into a `bar`"
        }

        listener.errorHandler = { _, error in
            if case .connectionInvalid = error as? XPCError {
                // connection can go down once we've received the last message
                return
            }

            DispatchQueue.main.async {
                XCTFail(error.localizedDescription)
            }
        }

        listener.activate()

        let failsToSendInvalidJoke = self.expectation(description: "Fails to send non-knock-knock joke")

        do {
            try await conn.sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)
        } catch let error as JokeMessage.NotAKnockKnockJoke {
            XCTAssertEqual(error.complaint, "That was not a knock knock joke!")
            failsToSendInvalidJoke.fulfill()
        }

        await fulfillment(of: [failsToSendInvalidJoke], timeout: 10.0)
    }

    func testOnewayVsTwoWay() async throws {
        let conn = try self.openConnection()

        var date = Date.now
        try await conn.sendMessage(name: CommandSet.pauseOneSecond)
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(date), 1.0)

        date = Date.now
        try conn.sendOnewayMessage(name: CommandSet.pauseOneSecond, message: XPCNull())
        XCTAssertLessThan(Date.now.timeIntervalSince(date), 0.5)
    }

    func testCancelConnection() async throws {
        let conn = try self.openConnection()

        let response: String = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "will work")
        XCTAssertEqual(response, "WILL WORK")

        conn.cancel()

        let err: Error?
        do {
            _ = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "won't work") as String
            err = nil
        } catch {
            err = error
        }

        guard case .connectionInvalid = err as? XPCError else {
            XCTFail("Sending message to cancelled connection should throw XPCError.connectionInvalid")
            return
        }
        
    }
    func testRawXPCDictionary() async throws {
        let conn = try self.openConnection()

        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(dictionary, "number", 42)
        xpc_dictionary_set_string(dictionary, "text", "hello world")

        print("Test sending dictionary with number: 42 and text: 'hello world'")

        let response = try await conn.sendRawMessage(
            name: CommandSet.rawDictionaryTest,
            dictionary: dictionary
        )

        debugXPCDictionary(response)

        if let doubleVal = xpc_dictionary_get_value(response, "doubledNumber") {
            let intValue = xpc_int64_get_value(doubleVal)
            XCTAssertEqual(intValue, 84)
        } else {
            XCTFail("Expected doubledNumber in response but it was nil")
        }

        if let uppercasedTextVal = xpc_dictionary_get_value(response, "uppercasedText") {
            if let uppercasedText = xpc_string_get_string_ptr(uppercasedTextVal) {
                let textValue = String(cString: uppercasedText)
                XCTAssertEqual(textValue, "HELLO WORLD")
            } else {
                XCTFail("Could not get string pointer from uppercasedText")
            }
        } else {
            XCTFail("Expected uppercasedText in response but it was nil")
        }
        if let timestampVal = xpc_dictionary_get_value(response, "timestamp") {
               let timestamp = xpc_date_get_value(timestampVal)
               XCTAssertNotEqual(timestamp, 0, "Timestamp should not be zero")

               let currentTime = Date().timeIntervalSince1970
               XCTAssertLessThan(abs(Int64(currentTime) - timestamp), 5, "Timestamp should be recent")
           } else {
               XCTFail("Response missing timestamp key")
           }

    }
    
    func testIOSurfaceTransfer() async throws {
        let conn = try self.openConnection()
        let device = MTLCreateSystemDefaultDevice()!
        
        struct IOSurfaceMessage: Codable, Sendable {
            public let size: Int64
        }
        let response = try await conn.sendMessageXPC(
            name: CommandSet.ioSurfaceTest,
            request: IOSurfaceMessage(size: 256)
        )
        
        let xpcResp  = xpc_dictionary_get_value(response, "iosurface")!
        let ioStuff = IOSurfaceLookupFromXPCObject(xpcResp)!
        let newBuff =  device.makeBuffer(bytesNoCopy: IOSurfaceGetBaseAddress(ioStuff),
                                         length: 256 * MemoryLayout<Float32>.stride,
                                         options: .storageModeShared,
                                         deallocator: nil)!
        XCTAssert(newBuff.contents().assumingMemoryBound(to: Float32.self)[0] == 2.0, "iosurface transfer failed or metal buffer creation failed")
        
    }
    
    func testIOSurfaceTransferCodable() async throws {
        let conn = try self.openConnection()
        let device = MTLCreateSystemDefaultDevice()!

        struct IOSurfaceMessage: Codable, Sendable {
            public let size: Int64
        }

        struct IOSurfaceResponse: Codable, Sendable {
            @IOSurfaceForXPC var surface: IOSurfaceRef
            let status: Int
            let message: String
        }

        let response = try await conn.sendMessage(
            name: CommandSet.ioSurfaceTestCodable,
            request: IOSurfaceMessage(size: 256)
        ) as IOSurfaceResponse

        let ioSurface = response.surface

        let newBuff = device.makeBuffer(
            bytesNoCopy: IOSurfaceGetBaseAddress(ioSurface),
            length: 256 * MemoryLayout<Float32>.stride,
            options: .storageModeShared,
            deallocator: nil
        )!

        // Verify the contents
        let floatPtr = newBuff.contents().assumingMemoryBound(to: Float32.self)
        XCTAssertEqual(floatPtr[0], 2.0, "IOSurface transfer failed or Metal buffer creation failed")

        // Optionally verify the status and message
        XCTAssertEqual(response.status, 200, "Expected success status code")
        XCTAssertEqual(response.message, "Success", "Expected success message")
    }


    

    func debugXPCDictionary(_ dict: xpc_object_t) {
        print("XPC Dictionary contents:")
        xpc_dictionary_apply(dict, { key, value in
            let keyString = String(cString: key)
            let type = xpc_get_type(value)

            var valueString = "unknown"
            if type == XPC_TYPE_INT64 {
                valueString = "\(xpc_int64_get_value(value))"
            } else if type == XPC_TYPE_STRING {
                if let strValue = xpc_string_get_string_ptr(value) {
                    valueString = "'\(String(cString: strValue))'"
                } else {
                    valueString = "nil string"
                }
            } else if type == XPC_TYPE_DATE {
                let timeValue = xpc_date_get_value(value)
                valueString = "date: \(Date(timeIntervalSince1970: TimeInterval(timeValue)))"
            } else {
                valueString = "type: \(type)"
            }

            print("  \(keyString) = \(valueString)")
            return true
        })
    }


    private func openConnection(codeSigningRequirement: String? = nil) throws -> XPCConnection {
        let conn = try XPCConnection(
            type: .remoteMachService(serviceName: helperID, isPrivilegedHelperTool: false),
            codeSigningRequirement: codeSigningRequirement ?? self.helperLauncher?.codeSigningRequirement
        )
        conn.activate()

        return conn
    }
}
