//
//  ViewController.swift
//  JocketDemo
//
//  Created by little2s on 16/5/20.
//  Copyright © 2016年 little2s. All rights reserved.
//

import UIKit
import SwiftyJocket

class ViewController: UIViewController {

    @IBOutlet weak var textField: UITextField!
    @IBOutlet weak var textView: UITextView!
    
    var jocket: Jocket?
    
    override func viewDidLoad() {
        super.viewDidLoad()

        openJocket()
    }

    @IBAction func sendMessage(sender: UIButton) {
        if textField.hasText() == false {
            return
        }
        
        guard let content = textField.text else { return }
        
        jocket?.sendPacket(["data": ["content": content]])
        
        let str = textView.text ?? ""
        textView.text = str + "Me: \(content)\n"
        
        textField.text = nil
        
        view.endEditing(true)
    }

    @IBAction func open(sender: UIButton) {
        if self.jocket != nil {
            showAlert("You have aleady connected.")
            return
        }
        
        openJocket()
    }

    @IBAction func close(sender: UIButton) {
        if self.jocket == nil {
            showAlert("You are not connected")
            return
        }
        
        closeJocket()
    }
    
    @IBAction func tapBlank(sender: UITapGestureRecognizer) {
        view.endEditing(true)
    }
    
    private func openJocket() {
        let url = NSURL(string: "http://192.168.2.115:8080/jocket/chat/simple")!
        
        let jocket = Jocket(url: url)
//        jocket.transports = [.Polling]
        
        jocket.onOpen = {
            print("connection open")
        }
        
        jocket.onClose = { error in
            print("connection closed. error code=\(error?.code)")
        }
        
        jocket.onPacket = { packet in
            print("receive packet json=\(packet)")
            
            
            
            guard let
                data = packet["data"] as? String,
                d = data.dataUsingEncoding(NSUTF8StringEncoding),
                json = try! NSJSONSerialization.JSONObjectWithData(d, options: NSJSONReadingOptions()) as? [String: AnyObject],
                senderType = json["senderType"] as? String,
                content = json["content"] as? String else {
                    return
            }
            
            if senderType == "self" {
                return
            }
            
            let str = self.textView.text ?? ""
            self.textView.text = str + "\(content)\n"
            
        }
        
        jocket.open()
        
        self.jocket = jocket
    }
    
    private func closeJocket() {
        jocket?.close()
        jocket = nil
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: "", message: message, preferredStyle: .Alert)
        alert.addAction(UIAlertAction(title: "OK", style: .Cancel, handler: nil))
        
        presentViewController(alert, animated: true, completion: nil)
    }

}

