import Foundation

/// Fallback for keyboard events without a Unicode payload, for the two
/// explicitly supported system layouts. Dead keys and IMEs are not guessed.
public enum KeyboardInput {
    private static let positions: [UInt16: Character] = [
        0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",
        12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",
        22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",
        32:"u",33:"[",34:"i",35:"p",37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",
        43:",",44:"/",45:"n",46:"m",47:".",50:"`"
    ]
    public static func character(code: UInt16, shift: Bool, capsLock: Bool, layout: Layout) -> String? {
        guard let base = positions[code] else { return nil }
        let shifted = Dictionary(uniqueKeysWithValues: zip(Array("`1234567890-=[]\\;',./"), Array("~!@#$%^&*()_+{}|:\"<>?")))
        var text = String(base)
        if layout == .russian { text = Conversion.convert(text, to: .russian) }
        if text.allSatisfy({ $0.isLetter }) {
            return shift != capsLock ? text.uppercased() : text.lowercased()
        }
        if shift, let key = shifted[base] {
            text = layout == .russian ? Conversion.convert(String(key), to: .russian) : String(key)
        }
        return text
    }
}
