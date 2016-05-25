//
//  Jocket.swift
//  SwiftyJocket
//
//  Created by little2s on 16/5/20.
//  Copyright © 2016年 little2s. All rights reserved.
//

import Foundation

public class Jocket {
    
    public typealias Packet = [String: AnyObject]
    
    public struct TransportOptions: OptionSetType {
        public var rawValue: Int = 0
        
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        
        public static var WebSocket = TransportOptions(rawValue: 1 << 0)
        public static var Polling = TransportOptions(rawValue: 1 << 1)
    }
    
    public enum CloseCode: Int {
        case Normal        = 1000  // normal closure
        case Away          = 1001  // close browser or reload page
        case Abnomal       = 1006  // network error
        case NeedInit      = 3600  // no jocket_sid passed to server
        case NoSession     = 3601  // the Jocket session specified by jocket_sid is not found
        case InitFailed    = 3602  // failed to open *.jocket_prepare
        case ConnectFailed = 3603  // all available transports failed
    }
    
    public static let ErrorDomain = "tw.com.chainsea.jocket"
    
    public var isOpen: Bool {
        if let trans = transport {
            return trans.isOpen
        } else {
            return false
        }
    }
    
    public var onOpen: (() -> Void)?
    public var onClose: ((NSError?) -> Void)?
    public var onPacket: ((Packet) -> Void)?
    
    public var transports: TransportOptions = [.WebSocket, .Polling]
    public var autoReconnect: Bool = false
    public var handshakeTimeout: NSTimeInterval = 3
    public var callbackQueue = dispatch_get_main_queue()
    
    public var url: NSURL
    public var sessionId: String?
    
    private var transport: TransportProtocol?
    private var isFirstConnection: Bool = true
    private var transportArray = [String]()
    private var transportTryIndex: Int = -1
    private var handshakeTimer: NSTimer?
    
    private static let transportQueue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)
    
    deinit {
        clearHandshakeTimer()
        
        transport?.close()
        transport = nil
    }
    
    public init(url: NSURL) {
        self.url = url
    }
    
    public static func setLogger(logger: JLoggerProtocol) {
        logging = logger
    }
    
    private static func closeError(code: CloseCode) -> NSError {
        let error = NSError(domain: ErrorDomain, code: code.rawValue, userInfo: nil)
        return error
    }
    
    public func open() {
        let prepare = prepareRequest()
        
        logging.debug("Open, prepareURL=\(prepare.URL!.absoluteString)")
        
        HttpWorker.request(prepare, completionHandler: handlePrepareResponse)
    }
    
    public func close() {
        logging.debug("Close, sessionId=\(sessionId)")
        
        destoryCurrentTransport()
        sessionId = nil
        
        dispatch_async(callbackQueue) {
            self.onClose?(Jocket.closeError(.Normal))
        }
    }
    
    public func sendPacket(packet: Packet) {
        logging.debug("Packet send: \(packet)")
        
        transport?.sendPacket(packet)
    }
    
    // MARK: Private methods
    private func prepareRequest() -> NSURLRequest {
        let url = NSURL(string: self.url.absoluteString + ".jocket_prepare")!
        let timeout: NSTimeInterval = 15
        
        var trans = [String]()
        if transports.contains(.WebSocket) {
            trans.append("websocket")
        }
        if transports.contains(.Polling) {
            trans.append("polling")
        }
        
        logging.debug("prepare trans=\(trans)")
        
        let request = NSMutableURLRequest(URL: url, cachePolicy: .ReloadIgnoringLocalCacheData, timeoutInterval: timeout)
        
        request.HTTPMethod = "POST"
        request.HTTPBody = dumpJSON(["transports": trans])
        
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
        
        return request
    }
    
    private func handlePrepareResponse(result: Result<JSONObject, NSError>) {
        switch result {
        case .Success(let json):
            guard let
                sid = json["sessionId"] as? String,
                trans = json["transports"] as? [String] else {
                    fatalError("Invalid server response")
            }
            
            logging.debug("Prepare success, sessionId=\(sid), transports=\(trans)")
            
            sessionId = sid
            transportArray = trans
            
            transportTryIndex = -1
            tryNextTransport()
            
        case .Failure(let error):
            logging.debug("Prepare failure, error=\(error)")
            
            dispatch_async(callbackQueue) {
                self.onClose?(error)
            }
        }
    }
    
    private func tryNextTransport() {
        transportTryIndex += 1
        if transportTryIndex >= transportArray.count {
            logging.debug("All tranports failure.")
            
            if isFirstConnection || !autoReconnect {
                logging.debug("Failed to make Jocket connection.")
                
                dispatch_async(callbackQueue) {
                    self.onClose?(Jocket.closeError(.ConnectFailed))
                }
                
            } else if autoReconnect {
                // TODO:
            }
            
            isFirstConnection = false
            return
        }
        
        let transportName = transportArray[transportTryIndex]
        var transport = createTransport(transportName)
        transport.onOpen = handleTransportOpen
        transport.onClose = handleTransportClose
        transport.onPacket = handleTransportPacket
        self.transport = transport
        
        logging.debug("Trying transport: sessionId=\(sessionId!), transport=\(transportName)")
        
        self.transport?.open()
        fireHandshakeTimer()
    }
    
    private func createTransport(transportName: String) -> TransportProtocol {
        let transport: TransportProtocol
        
        switch transportName {
        case "websocket":
            let str = (url.absoluteString as NSString).stringByReplacingOccurrencesOfString("http", withString: "ws") + "?jocket_sid=" + sessionId!
            transport = WebSocketTransport(url: NSURL(string: str)!, queue: Jocket.transportQueue)
        case "polling":
            let str = url.absoluteString + ".jocket_polling?jocket_sid=" + sessionId!
            transport = PollingTransport(url: NSURL(string: str)!)
        default:
            fatalError("Invalid transport response from server.")
        }
        
        return transport
    }
    
    private func handleTransportOpen() {
        sendPingPacket()
    }
    
    private func handleTransportClose(error: NSError?) {
        logging.debug("Transport close, error=\(error)")
        
        if handshakeTimer != nil {
            destoryCurrentTransport()
            tryNextTransport()
            return
        }
        
        dispatch_async(callbackQueue) {
            self.onClose?(error)
        }
    }
    
    private func handleTransportPacket(packet: Packet) {
        logging.debug("Packet recv: \(packet)")
        
        guard let type = packet["type"] as? String else {
            handleNormalPacket(packet)
            return
        }
        
        switch type {
        case "pong":
            handlePongPacket(packet)
        case "close":
            handleClosePacket(packet)
        default:
            handleNormalPacket(packet)
        }
    }
    
    private func sendPingPacket() {
        sendPacket(["type": "ping"])
    }
    
    private func sendOpenPacket() {
        sendPacket(["type": "open"])
    }
    
    private func handlePongPacket(packet: Packet) {
        if handshakeTimer != nil {
            clearHandshakeTimer()
            sendOpenPacket()
            
            dispatch_async(callbackQueue) {
                self.onOpen?()
            }
        }
    }
    
    private func handleClosePacket(packet: Packet) {
        destoryCurrentTransport()
        
        dispatch_async(callbackQueue) {
            self.onClose?(nil)
        }
    }
    
    private func handleNormalPacket(packet: Packet) {
        dispatch_async(callbackQueue) {
            self.onPacket?(packet)
        }
    }
    
    private func fireHandshakeTimer() {
        handshakeTimer = NSTimer(timeInterval: handshakeTimeout, target: self, selector: #selector(handleHandshakeTimeout), userInfo: nil, repeats: false)
        NSRunLoop.mainRunLoop().addTimer(handshakeTimer!, forMode: NSRunLoopCommonModes)
    }
    
    private func clearHandshakeTimer() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
    }
    
    @objc
    private func handleHandshakeTimeout() {
        destoryCurrentTransport()
        tryNextTransport()
    }
    
    
    private func destoryCurrentTransport() {
        transport?.close()
        transport = nil
    }

}

// MARK: Transport

typealias Packet = Jocket.Packet

protocol TransportProtocol {
    var isOpen: Bool { get }
    var onOpen: (() -> Void)? { get set }
    var onClose: ((NSError?) -> Void)? { get set }
    var onPacket: ((Packet) -> Void)? { get set }
    
    func open()
    func close()
    func sendPacket(packet: Packet)
}

// MARK: WebSocket
class WebSocketTransport: TransportProtocol {
    
    var isOpen: Bool {
        return socket.isConnected
    }
    
    var onOpen: (() -> Void)?
    var onClose: ((NSError?) -> Void)?
    var onPacket: ((Packet) -> Void)?
    
    private let socket: WebSocket
    
    deinit {
        socket.onConnect = nil
        socket.onDisconnect = nil
        socket.onText = nil
    }
    
    init(url: NSURL, queue: dispatch_queue_t) {
        socket = WebSocket(url: url)
        socket.queue = queue
        
        socket.onConnect = { [weak self] in
            self?.onOpen?()
        }
        
        socket.onDisconnect = { [weak self] error in
            self?.onClose?(error)
        }
        
        socket.onText = { [weak self] text in
            guard let
                data = text.dataUsingEncoding(NSUTF8StringEncoding),
                packet = parseJSON(data) else {
                    return
            }
            
            self?.onPacket?(packet)
        }
    }
    
    func open() {
        socket.connect()
    }
    
    func close() {
        socket.disconnect()
    }
    
    func sendPacket(packet: Packet) {
        guard let
            data = dumpJSON(packet),
            str = String(data: data, encoding: NSUTF8StringEncoding) else {
                return
        }
        
        socket.writeString(str)
    }
}

// MARK: Polling
class PollingTransport: TransportProtocol {
    
    var isOpen: Bool {
        guard let task = pollingTask else { return false }
        return task.state == .Running
    }
    
    var onOpen: (() -> Void)?
    var onClose: ((NSError?) -> Void)?
    var onPacket: ((Packet) -> Void)?
    
    var pollingTimeout: NSTimeInterval = 35
    var sendTimeout: NSTimeInterval = 15
    
    private var url: NSURL
    private var pollingTask: NSURLSessionDataTask?
    
    deinit {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    init(url: NSURL) {
        self.url = url
    }
    
    func open() {
        poll()
        onOpen?()
    }
    
    func close() {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    func sendPacket(packet: Packet) {
        let send = sendRequest(packet)
        HttpWorker.request(send) { result in
            // TODO:
        }
    }
    
    private func poll() {
        let polling = pollingRequest()
        pollingTask = HttpWorker.request(polling) { [weak self] result in
            guard let sSelf = self else { return }
            
            switch result {
            case .Success(let packet):
                
                sSelf.onPacket?(packet)
                sSelf.poll()
                
            case .Failure(let error):
                
                if error.domain == NSURLErrorDomain && error.code == -1001 {
                    // poll timeout, re-poll
                    sSelf.poll()
                    return
                }
                
                sSelf.onClose?(Jocket.closeError(.Abnomal))
            }
        }
    }
    
    private func pollingRequest() -> NSURLRequest {
        let url = self.url
        let timeout: NSTimeInterval = pollingTimeout
        
        let request = NSMutableURLRequest(URL: url, cachePolicy: .ReloadIgnoringLocalCacheData, timeoutInterval: timeout)
        
        request.HTTPMethod = "GET"
        
        return request
    }
    
    private func sendRequest(packet: Packet) -> NSURLRequest {
        let url = self.url
        let timeout: NSTimeInterval = sendTimeout
        
        let request = NSMutableURLRequest(URL: url, cachePolicy: .ReloadIgnoringLocalCacheData, timeoutInterval: timeout)
        
        request.HTTPMethod = "POST"
        request.HTTPBody = dumpJSON(packet)
        
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
        
        return request
    }
}

// MARK: Http worker
class HttpWorker {
    
    enum ErrorCode: Int {
        case ParseJSONFailed = -9001
        case HttpError       = -9002
    }
    
    static let ErrorDomain = "tw.com.chainsea.jocket.httpworker"
    
    private static let session: NSURLSession = {
        let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
        let session = NSURLSession(configuration: configuration)
        return session
    }()
    
    static func request(request: NSURLRequest, completionHandler: Result<JSONObject, NSError> -> Void)
        -> NSURLSessionDataTask
    {
        let req = request.mutableCopy() as! NSMutableURLRequest
        req.setValue("SwiftyJocket", forHTTPHeaderField: "Referer")
       
        let task = session.dataTaskWithRequest(req) { (data, response, error) in
            
            if let e = error {
                completionHandler(Result.Failure(e))
                return
            }
            
            guard let resp = response as? NSHTTPURLResponse where resp.statusCode == 200 else {
                let err = workerError(.HttpError)
                completionHandler(Result.Failure(err))
                return
            }
            
            guard let d = data, json = parseJSON(d) else {
                let err = workerError(.ParseJSONFailed)
                completionHandler(Result.Failure(err))
                return
            }

            completionHandler(Result.Success(json))
        }
        
        task.resume()

        return task
    }
    
    static func workerError(code: ErrorCode) -> NSError {
        let error = NSError(domain: ErrorDomain, code: code.rawValue, userInfo: nil)
        return error
    }
    
}



// MARK: JSON object
typealias JSONObject = [String: AnyObject]

func parseJSON(data: NSData) -> JSONObject? {
    guard let result = try? NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions()) else {
        return nil
    }
    
    if let dictionary = result as? JSONObject {
        return dictionary
    } else if let array = result as? [JSONObject] {
        // a little tricky here ...
        return ["data": array]
    } else {
        return nil
    }
}

func dumpJSON(json: JSONObject) -> NSData? {
    guard let data = try? NSJSONSerialization.dataWithJSONObject(json, options: NSJSONWritingOptions()) else {
        return nil
    }
    
    return data
}


// MARK: Result
enum Result<Value, Error> {
    case Success(Value)
    case Failure(Error)
    
    var isSuccess: Bool {
        switch self {
        case .Success:
            return true
        case .Failure:
            return false
        }
    }
    
    var isFailure: Bool {
        return !isSuccess
    }
    
    var value: Value? {
        switch self {
        case .Success(let value):
            return value
        case .Failure:
            return nil
        }
    }
    
    var error: Error? {
        switch self {
        case .Success:
            return nil
        case .Failure(let error):
            return error
        }
    }
}

// MARK: Logging
var logging: JLoggerProtocol = JLogger()

public protocol JLoggerProtocol {
    var enable: Bool { get set }
    
    func debug(@autoclosure closure: () -> String?)
}

struct JLogger: JLoggerProtocol {
    var enable: Bool = true
    
    func debug(@autoclosure closure: () -> String?) {
        if let msg = closure() {
            NSLog("[Jocket] \(msg)")
        }
    }
}
