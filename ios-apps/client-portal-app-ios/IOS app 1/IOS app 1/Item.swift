//
//  Item.swift
//  IOS app 1
//
//  Created by Grant Corp on 3/29/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
