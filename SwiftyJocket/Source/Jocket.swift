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
    
    public enum CloseCode: Int {
        case Normal          = 1000  // normal closure
        case Away            = 1001  // close browser or reload page
        case Abnomal         = 1006  // network error
        case NoSessionParam  = 3600  // the Jocket session ID parameter is missing
        case SessionNotFound = 3601  // the Jocket session is not found
        case CreateFailed    = 3602  // failed to create Jocket session
        case ConnectFailed   = 3603  // failed to connect to server
        case PingTimeout     = 3604  // ping timeout
        case PollingFailed   = 3605  // polling failed
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
    
    public var autoReconnect: Bool = false
    public var callbackQueue = dispatch_get_main_queue()
    
    public var baseURL: NSURL
    public var appName: String
    public var path: String
    
    public var sessionId: String?
    public var upgradable: Bool = false
    public var pingInterval: NSTimeInterval = 25
    public var pingTimeout: NSTimeInterval = 20
    
    private var transport: TransportProtocol?
    private var handshakeTimer: NSTimer?
    private var heartbeatTimer: NSTimer?
    
    private static let transportQueue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)
    
    deinit {
        clearHandshakeTimer()
        clearHeartbeatTimer()
        destoryCurrentTransport()
    }
    
    public init(baseURL: NSURL, appName: String, path: String) {
        self.baseURL = baseURL
        self.appName = appName
        self.path = path
    }
    
    public static func setLogger(logger: JLoggerProtocol) {
        JLog = logger
    }
    
    private static func closeError(code: CloseCode) -> NSError {
        let error = NSError(domain: ErrorDomain, code: code.rawValue, userInfo: nil)
        return error
    }
    
    public func open() {
        let req = createRequest()
        
        JLog.debug("Open, create url=\(req.URL!.absoluteString)")
        
        HttpWorker.request(req, completionHandler: handleCreateResponse)
    }
    
    public func close() {
        JLog.debug("Close, sessionId=\(sessionId)")
        
        destoryCurrentTransport()
        sessionId = nil
        
        dispatch_async(callbackQueue) {
            self.onClose?(Jocket.closeError(.Normal))
        }
    }
    
    public func sendPacket(packet: Packet) {
        JLog.debug("Packet send: \(packet)")
        
        transport?.sendPacket(packet)
    }
    
    // MARK: Private methods
    private func createRequest() -> NSURLRequest {
        let str = "\(baseURL.absoluteString)/\(appName)/\(path).jocket"
        
        let url = NSURL(string: str)!
        let timeout: NSTimeInterval = 15
        
        let request = NSMutableURLRequest(URL: url, cachePolicy: .ReloadIgnoringLocalCacheData, timeoutInterval: timeout)
        
        request.HTTPMethod = "GET"
        
        request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
        
        return request
    }
    
    private func handleCreateResponse(result: JResult<JObject, NSError>) {
        switch result {
        case .Success(let json):
            JLog.debug("Create success, json=\(json)")
            
            guard let
                sessionId = json["sessionId"] as? String,
                upgradable = (json["upgradable"] as? NSNumber)?.boolValue,
                pingInterval = (json["pingInterval"] as? NSNumber)?.doubleValue,
                pingTimeout = (json["pingTimeout"] as? NSNumber)?.doubleValue else {
                    fatalError("Invalid server response")
            }
            
            
            self.sessionId = sessionId
            self.upgradable = upgradable
            self.pingInterval = pingInterval / 1000
            self.pingTimeout = pingTimeout / 1000
            
            fireHandshakeTimer()
            startPollingTransport()
            
        case .Failure(let error):
            JLog.debug("Create failure, error=\(error)")
            
            dispatch_async(callbackQueue) {
                self.onClose?(error)
            }
        }
    }
    
    private func startPollingTransport() {
        let str = "\(baseURL.absoluteString)/\(appName)/jocket?s=\(sessionId!)"
        
        transport = PollingTransport(url: NSURL(string: str)!)
        transport?.onOpen = handleTransportOpen
        transport?.onClose = handleTransportClose
        transport?.onPacket = handleTransportPacket
        
        JLog.debug("Trying polling: sessionId=\(sessionId!)")
        
        self.transport?.open()
    }
    
    private func handleTransportOpen() {
        if handshakeTimer != nil {
            sendPingPacket()
        }
    }
    
    private func handleTransportClose(error: NSError?) {
        JLog.debug("Transport close, error=\(error)")
        
        destoryCurrentTransport()
        
        dispatch_async(callbackQueue) {
            self.onClose?(error)
        }
    }
    
    private func handleTransportPacket(packet: Packet) {
        JLog.debug("Packet recv: \(packet)")
        
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
    
    private func handlePongPacket(packet: Packet) {
        if handshakeTimer != nil {
            clearHandshakeTimer()
            fireHeartbeatTimer()
            
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
        handshakeTimer = NSTimer(timeInterval: pingTimeout, target: self, selector: #selector(handleHandshakeTimeout), userInfo: nil, repeats: false)
        NSRunLoop.mainRunLoop().addTimer(handshakeTimer!, forMode: NSRunLoopCommonModes)
    }
    
    private func clearHandshakeTimer() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
    }
    
    @objc
    private func handleHandshakeTimeout() {
        destoryCurrentTransport()
    }
    
    private func fireHeartbeatTimer() {
        heartbeatTimer = NSTimer(timeInterval: pingInterval, target: self, selector: #selector(handleHeartbeatTimeout), userInfo: nil, repeats: true)
        NSRunLoop.mainRunLoop().addTimer(heartbeatTimer!, forMode: NSRunLoopCommonModes)
    }
    
    private func clearHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    @objc
    private func handleHeartbeatTimeout() {
        sendPingPacket()
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
                packet = parseJObject(data) else {
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
            data = dumpJObject(packet),
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
    
    var pollingTimeout: NSTimeInterval = 3600
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
        sendPacket(["type": "close"])
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
        request.HTTPBody = dumpJObject(packet)
        
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
    
    static func request(request: NSURLRequest, completionHandler: JResult<JObject, NSError> -> Void)
        -> NSURLSessionDataTask
    {
        let req = request.mutableCopy() as! NSMutableURLRequest
        req.setValue("SwiftyJocket", forHTTPHeaderField: "Referer")
       
        let task = session.dataTaskWithRequest(req) { (data, response, error) in
            
            if let e = error {
                completionHandler(JResult.Failure(e))
                return
            }
            
            guard let resp = response as? NSHTTPURLResponse where resp.statusCode == 200 else {
                debugPrint("http resp=\(response)")
                
                let err = workerError(.HttpError)
                completionHandler(JResult.Failure(err))
                return
            }
            
            guard let d = data, json = parseJObject(d) else {
                let err = workerError(.ParseJSONFailed)
                completionHandler(JResult.Failure(err))
                return
            }

            completionHandler(JResult.Success(json))
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
typealias JObject = [String: AnyObject]

func parseJObject(data: NSData) -> JObject? {
    guard let result = try? NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions()) else {
        return nil
    }
    
    if let dictionary = result as? JObject {
        return dictionary
    } else if let array = result as? [JObject] {
        // a little tricky here ...
        return ["data": array]
    } else {
        return nil
    }
}

func dumpJObject(json: JObject) -> NSData? {
    guard let data = try? NSJSONSerialization.dataWithJSONObject(json, options: NSJSONWritingOptions()) else {
        return nil
    }
    
    return data
}


// MARK: JResult
enum JResult<Value, Error> {
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
var JLog: JLoggerProtocol = JLogger()

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
