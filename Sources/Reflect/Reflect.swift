
//
// This file is derived from the ABI notes available as part of the Swift Open Source project.
//     https://github.com/apple/swift/blob/master/docs/ABI.rst
//

func reflect(type: Any.Type) -> Type {

    let flag = unsafeBitCast(type, to: UnsafePointer<Int>.self).pointee
    let kind = Type.Kind(flag: flag)
    switch kind {
    case .struct:
        return StructType(type: type)

    case .tuple:
        return TupleType(type: type)

    case .enum, .optional:
        return EnumType(type: type)

    case .function:
        return FunctionType(type: type)

    case .existential:
        return ExistentialType(type: type)

    default:
        return Type(type: type)
    }
}

class Type: Equatable {
    var pointer: UnsafeRawPointer

    var kind: Kind {
        return Kind(flag: pointer.assumingMemoryBound(to: Int.self).pointee)
    }

    var type: Any.Type {
        return unsafeBitCast(self, to: Any.Type.self)
    }

    init(type: Any.Type) {
        self.pointer = unsafeBitCast(type, to: UnsafeRawPointer.self)
    }

    static func == (lhs: Type, rhs: Type) -> Bool {
        return lhs.pointer == rhs.pointer
    }
}

final class StructType: Type {

    var nominalTypeDescriptorOffset: Int {
        return 1
    }

    var nominalTypeDescriptorPointer: UnsafeRawPointer {
        let relpointer = self.pointer.advanced(by: nominalTypeDescriptorOffset * word)
        return relpointer.advanced(by: relpointer.load(as: Int.self))
    }

    // MARK: Nominal Type Descriptor

    // NOTE(vdka): Not sure why but all the offset's mentioned in the ABI for Nominal Type Descriptors are off by 1. The pointer we have points to the mangled name offset.

    var mangledName: String {
        let offset = 0

        let relpointer = nominalTypeDescriptorPointer.advanced(by: offset * halfword)
        let pointer = relpointer.advanced(by: Int(relpointer.load(as: Int32.self)))
            .assumingMemoryBound(to: CChar.self)

        return String(cString: pointer)
    }

    var numberOfFields: Int {
        let offset = 1
        let pointer = nominalTypeDescriptorPointer.advanced(by: offset * halfword)
        return numericCast(pointer.load(as: Int32.self))
    }

    var fieldOffsets: [Int] {
        let offset = 2

        let base = self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset + nominalTypeDescriptorOffset)

        var offsets: [Int] = []
        for index in 0..<numberOfFields {
            offsets.append(base.advanced(by: index).pointee)
        }

        return offsets
    }

    var fieldNames: [String] {
        let offset = 3

        let relpointer = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let pointer = relpointer.advanced(by: relpointer.load(as: Int32.self))

        return Array(utf8Strings: pointer.assumingMemoryBound(to: CChar.self))
    }

    //
    // from ABI.rst:
    //
    // The field type accessor is a function pointer at offset 5. If non-null, the function takes a pointer to an
    //   instance of type metadata for the nominal type, and returns a pointer to an array of type metadata
    //   references for the types of the fields of that instance. The order matches that of the field offset vector
    //   and field name list.
    typealias FieldsTypeAccessor = @convention(c) (UnsafeRawPointer) -> UnsafePointer<UnsafeRawPointer>
    var fieldTypesAccessor: FieldsTypeAccessor? {
        let offset = 4

        let relpointer = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let pointer = relpointer.advanced(by: relpointer.load(as: Int32.self))
        guard relpointer != pointer else { return nil }

        return unsafeBitCast(pointer, to: FieldsTypeAccessor.self)
    }

    var fieldTypes: [Type]? {
        guard let accessorFunction = fieldTypesAccessor else { return nil }

        var types: [Type] = []
        for fieldIndex in 0..<numberOfFields {
            let pointer = accessorFunction(nominalTypeDescriptorPointer).advanced(by: fieldIndex).pointee
            let type = unsafeBitCast(pointer, to: Type.self)
            types.append(type)
        }

        return types
    }

    var isGeneric: Bool {
        let offset = 6
        let pointer = self.nominalTypeDescriptorPointer.advanced(by: offset * word)
            .assumingMemoryBound(to: Int.self)
        return pointer.pointee != 0
    }
}

final class EnumType: Type {

    var isOptionalType: Bool {
        return kind == .optional
    }

    var nominalTypeDescriptorOffset: Int {
        return 1
    }

    var nominalTypeDescriptorPointer: UnsafeRawPointer {
        let pointer = self.pointer.assumingMemoryBound(to: Int.self)
        let base = pointer.advanced(by: nominalTypeDescriptorOffset)
        return UnsafeRawPointer(base).advanced(by: base.pointee)
    }

    var mangledName: String {
        let offset = 0

        let relpointer = nominalTypeDescriptorPointer.advanced(by: offset * halfword)
        let pointer = relpointer.advanced(by: Int(relpointer.load(as: Int32.self)))
            .assumingMemoryBound(to: CChar.self)

        return String(cString: pointer)
    }

    var numberOfPayloadCases: Int {
        let offset = 1
        let val = nominalTypeDescriptorPointer.advanced(by: offset * halfword).load(as: Int32.self)
        return numericCast(val & 0x0FFF)
    }

    var payloadSizeOffset: Int {
        let offset = 1
        let val = nominalTypeDescriptorPointer.advanced(by: offset * halfword).load(as: Int32.self)
        return numericCast(val & 0xF000)
    }

    var numberOfNoPayloadCases: Int {
        let offset = 2
        let val = nominalTypeDescriptorPointer.advanced(by: offset * halfword).load(as: Int32.self)
        return numericCast(val)
    }

    var numberOfCases: Int {
        return numberOfPayloadCases + numberOfNoPayloadCases
    }

    // Order is payload cases first then non payload cases, in those segments the order is source order.
    var caseNames: [String] {
        let offset = 3
        let relpointer = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let pointer = relpointer.advanced(by: relpointer.load(as: Int32.self))
            .assumingMemoryBound(to: CChar.self)

        return Array(utf8Strings: pointer)
    }

    typealias CaseTypeAccessor = @convention(c) (UnsafeRawPointer) -> UnsafePointer<UnsafeRawPointer>
    var caseTypesAccessor: CaseTypeAccessor? { // offset 4
        let offset = 4

        let relpointer = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let pointer = relpointer.advanced(by: relpointer.load(as: Int32.self))
        guard relpointer != pointer else { return nil }

        return unsafeBitCast(pointer, to: CaseTypeAccessor.self)
    }

    var caseTypes: [Any.Type]? {
        guard let accessorFunction = caseTypesAccessor else { return nil }

        var types: [Any.Type] = []
        for caseIndex in 0..<numberOfPayloadCases {
            let pointer = accessorFunction(self.pointer).advanced(by: caseIndex).pointee

            // > the least significant bit of each element in the result is set if the enum case is an indirect case.
            var typePointer = Int(bitPattern: pointer)
            typePointer &= ~1

            let type = unsafeBitCast(typePointer, to: Any.Type.self)
            types.append(type)
        }

        return types
    }

    func isIndirect(at index: Int) -> Bool {
        precondition(index < numberOfCases)
        guard let accessorFunction = caseTypesAccessor else { return false }

        let pointer = accessorFunction(self.pointer).advanced(by: index).pointee

        let pointerBits = Int(bitPattern: pointer)
        return (pointerBits & 0b1) == 1
    }

    var isGeneric: Bool {
        let offset = 3
        let pointer = self.pointer.advanced(by: offset * word)
            .assumingMemoryBound(to: Int.self)
        return pointer.pointee != 0
    }
}

final class TupleType: Type {

    var numberOfElements: Int {
        let offset = 1
        return pointer.advanced(by: offset * word).load(as: Int.self)
    }

    var elementTypes: [Any.Type] {
        let offset = 3

        let pointer = self.pointer.advanced(by: offset * word).assumingMemoryBound(to: Int.self)

        var types: [Any.Type] = []

        for index in 0..<numberOfElements {
            let type = unsafeBitCast(pointer.advanced(by: 2 * index).pointee, to: Any.Type.self)
            types.append(type)
        }

        return types
    }

    var elementOffsets: [Int] {
        let offset = 3

        let pointer = self.pointer.advanced(by: offset * word).assumingMemoryBound(to: Int.self)

        var offsets: [Int] = []

        for index in 0..<numberOfElements {
            offsets.append(pointer.advanced(by: 2 * index + 1).pointee)
        }

        return offsets
    }
}

class FunctionType: Type {

    var numberOfArguments: Int {
        let offset = 1
        return pointer.advanced(by: offset * word).load(as: Int.self)
    }

    var resultType: Type {
        let offset = 2
        let ty = pointer.advanced(by: offset * word).load(as: Any.Type.self)
        return reflect(type: ty)
    }

    var argumentTypes: [Type] {
        return (0..<numberOfArguments).map(argumentType(at:))
    }

    func argumentType(at index: Int) -> Type {
        precondition(index < numberOfArguments)
        let offset = 3

        var pointer = self.pointer.advanced(by: offset * word)

        let firstTypePointer = UnsafeRawPointer(bitPattern: pointer.load(as: Int.self) & (~0b1))!
        if numberOfArguments == 1 {
            let type = unsafeBitCast(firstTypePointer, to: Any.Type.self)
            return reflect(type: type)
        }

        // This is messy, if the first argument is not a tuple then we know that atleast 1 argument is inout.
        //   otherwise if the first argument is a tuple then we must check to see if it has the same number of
        //   elements as the number of arguments we are expecting.

        let firstType = unsafeBitCast(firstTypePointer, to: Any.Type.self)

        if let tupleType = reflect(type: firstType) as? TupleType, tupleType.numberOfElements == numberOfArguments {
            return tupleType
        }

        pointer = pointer.advanced(by: index * word)
        let typePointer = UnsafeRawPointer(bitPattern: pointer.load(as: Int.self) & (~0b1))!
        let type = unsafeBitCast(typePointer, to: Any.Type.self)
        return reflect(type: type)
    }

    func isParamInout(at index: Int) -> Bool {
        precondition(index < numberOfArguments)
        let offset = 3

        let pointerValue = self.pointer.advanced(by: (offset + index) * word).load(as: Int.self)
        return (pointerValue & 0b1) == 1
    }

    var hasInoutArguments: Bool {
        let offset = 3

        var pointer = self.pointer.advanced(by: offset * word)

        if (pointer.load(as: Int.self) & 0b1) == 1 {
            return true
        }

        let firstType = unsafeBitCast(pointer, to: Any.Type.self)

        if let tupleType = reflect(type: firstType) as? TupleType, tupleType.numberOfElements == numberOfArguments {
            return false
        }

        for index in 1 ..< numberOfArguments {
            pointer = pointer.advanced(by: index * word)

            if (pointer.load(as: Int.self) & 0b1) == 1 {
                return true
            }
        }

        return false
    }
}

/**
 The protocol descriptor vector begins at offset 3. This is an inline array of pointers to the protocol descriptor for every protocol in the composition, or the single protocol descriptor for a protocol type. For an "any" type, there is no protocol descriptor vector.
*/
class ExistentialType: Type {

    // The number of witness tables is stored in the least significant 31 bits. Values of the protocol type contain this number of witness table pointers in
    //   their layout.
    var numberOfWitnessTables: Int {
        let offset = 1
        let mask = 0x7FFFFFFF
        let pointer = self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset)
        return pointer.pointee & mask
    }

    // If (bit 31) not set, then only class values can be stored in the type, and the type uses a more efficient layout.
    var hasClassConstraint: Bool {
        let offset = 1
        let mask = 0x80000000
        let pointer = self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset)
        return (pointer.pointee & mask) == 0
    }

    /// - Note: For the "any" types `Any` or `Any: class`, this is zero
    var numberOfProtocolsMakingComposition: Int {
        let offset = 2
        let pointer = self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset)
        return pointer.pointee
    }

    var isAnyType: Bool {
        return (numberOfProtocolsMakingComposition == 0) && !hasClassConstraint
    }

    var isAnyClassType: Bool {
        return (numberOfProtocolsMakingComposition == 0) && hasClassConstraint
    }

    var protocolDescriptorVectorPointer: UnsafeBufferPointer<UnsafePointer<ProtocolDescriptor>> {
        let offset = 3
        let pointer = self.pointer.assumingMemoryBound(to: UnsafePointer<ProtocolDescriptor>.self).advanced(by: offset)
        let buffer = UnsafeBufferPointer(start: pointer, count: numberOfProtocolsMakingComposition)
        return buffer
    }

    var protocolDescriptors: [ProtocolDescriptor] {

        return protocolDescriptorVectorPointer.map({ $0.pointee })
    }
}

struct ProtocolDescriptor {
    var isa: Int
    var mangledName: UnsafePointer<CChar>
    var inheritedProtocolList: Int
    var objcA: Int
    var objcB: Int
    var objcC: Int
    var objcD: Int
    var objcE: Int
    var size: Int32
    var flags: Int32
}

extension Type {
    enum Kind {
        case `struct`
        case `enum`
        case optional
        case opaque
        case tuple
        case function
        case existential
        case metatype
        case objCClassWrapper
        case existentialMetatype
        case foreignClass
        case heapLocalVariable
        case heapGenericLocalVariable
        case errorObject
        case `class`
        init(flag: Int) {
            switch flag {
            case 1: self = .struct
            case 2: self = .enum
            case 3: self = .optional
            case 8: self = .opaque
            case 9: self = .tuple
            case 10: self = .function
            case 12: self = .existential
            case 13: self = .metatype
            case 14: self = .objCClassWrapper
            case 15: self = .existentialMetatype
            case 16: self = .foreignClass
            case 64: self = .heapLocalVariable
            case 65: self = .heapGenericLocalVariable
            case 128: self = .errorObject
            default: self = .class
            }
        }
    }
}

internal extension UnsafeRawPointer {

    func advanced(by offset: Int32) -> UnsafeRawPointer {
        return self.advanced(by: Int(offset))
    }
}






// MARK: Old

protocol AnyExtensions {}

extension AnyExtensions {
    static func write(_ value: Any, to storage: UnsafeMutableRawPointer) {
        guard let this = value as? Self else {
            fatalError("Internal logic error")
        }
        storage.assumingMemoryBound(to: self).initialize(to: this)
    }

    static var isOptional: Bool {

        let metadata = Metadata(type: self)

        guard case .optional = metadata.kind else {
            return false
        }

        return true
    }
}

/// Magic courtesy of Zewo/Reflection
func extensions(of type: Any.Type) -> AnyExtensions.Type {
    struct Extensions : AnyExtensions {}
    var extensions: AnyExtensions.Type = Extensions.self
    withUnsafePointer(to: &extensions) { pointer in
        UnsafeMutableRawPointer(mutating: pointer).assumingMemoryBound(to: Any.Type.self).pointee = type
    }
    return extensions
}

protocol MetadataType {
    var pointer: UnsafeRawPointer { get }
    static var kind: Metadata.Kind? { get }
}

extension MetadataType {
    var valueWitnessTable: ValueWitnessTable {
        return ValueWitnessTable(pointer: pointer.assumingMemoryBound(to: UnsafeRawPointer.self).advanced(by: -1).pointee)
    }

    var kind: Metadata.Kind {
        return Metadata.Kind(flag: pointer.assumingMemoryBound(to: Int.self).pointee)
    }

    init(pointer: UnsafeRawPointer) {
        self = unsafeBitCast(pointer, to: Self.self)
    }

    init?(type: Any.Type) {
        self.init(pointer: unsafeBitCast(type, to: UnsafeRawPointer.self))

        switch (type(of: self).kind, self.kind) {
        case (.enum?, .optional): // an optional is an enum with extra
            break

        default:
            if let kind = type(of: self).kind, kind != self.kind {
                return nil
            }
        }
    }
}

struct Metadata: MetadataType {
    var pointer: UnsafeRawPointer

    init(type: Any.Type) {
        self.pointer = unsafeBitCast(type, to: UnsafeRawPointer.self)
    }
}

// https://github.com/apple/swift/blob/swift-3.0-branch/include/swift/ABI/MetadataKind.def
extension Metadata {
    static let kind: Kind? = nil

    enum Kind {
        case `struct`
        case `enum`
        case optional
        case opaque
        case tuple
        case function
        case existential
        case metatype
        case objCClassWrapper
        case existentialMetatype
        case foreignClass
        case heapLocalVariable
        case heapGenericLocalVariable
        case errorObject
        case `class`
        init(flag: Int) {
            switch flag {
            case 1: self = .struct
            case 2: self = .enum
            case 3: self = .optional
            case 8: self = .opaque
            case 9: self = .tuple
            case 10: self = .function
            case 12: self = .existential
            case 13: self = .metatype
            case 14: self = .objCClassWrapper
            case 15: self = .existentialMetatype
            case 16: self = .foreignClass
            case 64: self = .heapLocalVariable
            case 65: self = .heapGenericLocalVariable
            case 128: self = .errorObject
            default: self = .class
            }
        }
    }
}

// https://github.com/apple/swift/blob/master/lib/IRGen/ValueWitness.h
struct ValueWitnessTable {
    var pointer: UnsafeRawPointer

    private var alignmentMask: Int {
        return 0x0FFFF
    }

    var size: Int {
        return pointer.assumingMemoryBound(to: _ValueWitnessTable.self).pointee.size
    }

    var align: Int {
        return (pointer.assumingMemoryBound(to: _ValueWitnessTable.self).pointee.align & alignmentMask) + 1
    }

    var stride: Int {
        return pointer.assumingMemoryBound(to: _ValueWitnessTable.self).pointee.stride
    }
}

struct _ValueWitnessTable {
    let destroyBuffer: Int
    let initializeBufferWithCopyOfBuffer: Int
    let projectBuffer: Int
    let deallocateBuffer: Int
    let destroy: Int
    let initializeBufferWithCopy: Int
    let initializeWithCopy: Int
    let assignWithCopy: Int
    let initializeBufferWithTake: Int
    let initializeWithTake: Int
    let assignWithTake: Int
    let allocateBuffer: Int
    let initializeBufferWithTakeOrBuffer: Int
    let destroyArray: Int
    let initializeArrayWithCopy: Int
    let initializeArrayWithTakeFrontToBack: Int
    let initializeArrayWithTakeBackToFront: Int
    let size: Int
    let align: Int
    let stride: Int
}


extension Metadata {
    // https://github.com/apple/swift/blob/master/docs/ABI.rst#tuple-metadata
    struct Tuple: MetadataType {
        static let kind: Kind? = .tuple
        var pointer: UnsafeRawPointer
    }
}

extension Metadata.Tuple {

    var numberOfElements: Int {
        let offset = 1
        let pointer = UnsafeRawPointer(self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset)).assumingMemoryBound(to: Int.self)
        return pointer.pointee
    }

    var elementTypes: [Any.Type] {
        let offset = 3
        let pointer = UnsafeRawPointer(self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset)).assumingMemoryBound(to: Int.self)

        var types: [Any.Type] = []

        for index in 0..<numberOfElements {
            let type = unsafeBitCast(pointer.advanced(by: 2 * index).pointee, to: Any.Type.self)
            types.append(type)
        }

        return types
    }

    var elementOffsets: [Int] {
        let offset = 3
        let pointer = UnsafeRawPointer(self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset)).assumingMemoryBound(to: Int.self)

        var offsets: [Int] = []

        for index in 0..<numberOfElements {
            offsets.append(pointer.advanced(by: 2 * index + 1).pointee)
        }

        return offsets
    }
}

extension Metadata {
    struct Struct: MetadataType {
        static let kind: Kind? = .struct
        var pointer: UnsafeRawPointer
    }
}

extension Metadata.Struct {
    var nominalTypeDescriptorOffset: Int {
        return 1
    }

    var nominalTypeDescriptorPointer: UnsafeRawPointer {
        let pointer = self.pointer.assumingMemoryBound(to: Int.self)
        let base = pointer.advanced(by: nominalTypeDescriptorOffset)
        return UnsafeRawPointer(base).advanced(by: base.pointee)
    }

    var fieldOffsets: [Int] {
        let offset = 3
        let base = UnsafeRawPointer(self.pointer.assumingMemoryBound(to: Int.self).advanced(by: offset)).assumingMemoryBound(to: Int.self)

        var offsets: [Int] = []

        for index in 0..<numberOfFields {
            offsets.append(base.advanced(by: index).pointee)
        }

        return offsets
    }

    // NOTE: The rest of the struct Metadata is stored on the NominalTypeDescriptor

    // NOTE(vdka): Not sure why but all the offset's mentioned in the ABI for Nominal Type Descriptors are off by 1. The pointer we have points to the mangled name offset.

    var mangledName: String { // offset 0

        let offset = nominalTypeDescriptorPointer.assumingMemoryBound(to: Int32.self).pointee
        let p = nominalTypeDescriptorPointer.advanced(by: offset).assumingMemoryBound(to: CChar.self)
        return String(cString: p)
    }

    var numberOfFields: Int { // offset 1

        let offset = 1
        return numericCast(nominalTypeDescriptorPointer.load(fromByteOffset: offset * halfword, as: Int32.self))
    }

    var fieldNames: [String] { // offset 3

        let offset = 3
        let base = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let dataOffset = base.load(as: Int32.self)
        let fieldNamesPointer = base.advanced(by: dataOffset)

        return Array(utf8Strings: fieldNamesPointer.assumingMemoryBound(to: CChar.self))
    }

    //
    // from ABI.rst:
    //
    // The field type accessor is a function pointer at offset 5. If non-null, the function takes a pointer to an
    //   instance of type metadata for the nominal type, and returns a pointer to an array of type metadata
    //   references for the types of the fields of that instance. The order matches that of the field offset vector
    //   and field name list.
    typealias FieldsTypeAccessor = @convention(c) (UnsafeRawPointer) -> UnsafePointer<UnsafeRawPointer>
    var fieldTypesAccessor: FieldsTypeAccessor? { // offset 4

        let offset = 4
        let base = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let dataOffset = base.load(as: Int32.self)
        guard dataOffset != 0 else { return nil }

        let dataPointer = base.advanced(by: dataOffset)
        return unsafeBitCast(dataPointer, to: FieldsTypeAccessor.self)
    }

    var fieldTypes: [Any.Type]? {
        guard let accessorFunction = fieldTypesAccessor else { return nil }

        var types: [Any.Type] = []
        for fieldIndex in 0..<numberOfFields {
            let pointer = accessorFunction(nominalTypeDescriptorPointer).advanced(by: fieldIndex).pointee
            let type = unsafeBitCast(pointer, to: Any.Type.self)
            types.append(type)
        }

        return types
    }
}

extension Metadata {
    // https://github.com/apple/swift/blob/master/docs/ABI.rst#enum-metadata
    struct Enum: MetadataType {
        static let kind: Kind? = .enum
        var pointer: UnsafeRawPointer
    }
}

extension Metadata.Enum {
    var nominalTypeDescriptorOffset: Int {
        return 1
    }

    var nominalTypeDescriptorPointer: UnsafeRawPointer {
        let pointer = self.pointer.assumingMemoryBound(to: Int.self)
        let base = pointer.advanced(by: nominalTypeDescriptorOffset)
        return UnsafeRawPointer(base).advanced(by: base.pointee)
    }

    var mangledName: String { // offset 0

        let offset = nominalTypeDescriptorPointer.assumingMemoryBound(to: Int32.self).pointee
        let p = nominalTypeDescriptorPointer.advanced(by: offset).assumingMemoryBound(to: CChar.self)
        return String(cString: p)
    }

    var numberOfPayloadCases: Int { // offset 1

        let offset = 1
        let val = nominalTypeDescriptorPointer.load(fromByteOffset: offset * halfword, as: Int32.self)
        return numericCast(val & 0x0FFF)
    }

    var payloadSizeOffset: Int { // offset 1
        let offset = 1
        let val = nominalTypeDescriptorPointer.load(fromByteOffset: offset * halfword, as: Int32.self)
        return numericCast(val & 0xF000)
    }

    var numberOfNoPayloadCases: Int { // offset 2
        let offset = 2
        let val = nominalTypeDescriptorPointer.load(fromByteOffset: offset * halfword, as: Int32.self)
        return numericCast(val)
    }

    var numberOfCases: Int {
        return numberOfPayloadCases + numberOfNoPayloadCases
    }

    // Order is payload cases first then non payload cases, in those segments the order is source order.
    var caseNames: [String] { // offset 3
        let offset = 3
        let base = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let dataOffset = base.load(as: Int32.self)
        let fieldNamesPointer = base.advanced(by: dataOffset)

        return Array(utf8Strings: fieldNamesPointer.assumingMemoryBound(to: CChar.self))
    }

    typealias CaseTypeAccessor = @convention(c) (UnsafeRawPointer) -> UnsafePointer<UnsafeRawPointer>
    var caseTypesAccessor: CaseTypeAccessor? { // offset 4

        let offset = 4
        let base = nominalTypeDescriptorPointer.advanced(by: offset * halfword)

        let dataOffset = base.load(as: Int32.self)
        guard dataOffset != 0 else { return nil }

        let dataPointer = base.advanced(by: dataOffset)
        return unsafeBitCast(dataPointer, to: CaseTypeAccessor.self)
    }

    var caseTypes: [Any.Type]? {
        guard let accessorFunction = caseTypesAccessor else { return nil }

        var types: [Any.Type] = []
        for caseIndex in 0..<numberOfPayloadCases {
            let pointer = accessorFunction(self.pointer).advanced(by: caseIndex).pointee

            // > the least significant bit of each element in the result is set if the enum case is an indirect case.
            var typePointer = Int(bitPattern: pointer)
            typePointer &= ~1

            let type = unsafeBitCast(typePointer, to: Any.Type.self)
            types.append(type)
        }

        return types
    }
}


// MARK: - Helpers

let word = min(MemoryLayout<Int>.size, MemoryLayout<Int64>.size)
let halfword = word / 2

extension Array where Element == String {

    init(utf8Strings: UnsafePointer<CChar>) {
        var strings = [String]()
        var pointer = utf8Strings

        while true {
            let string = String(cString: pointer)
            strings.append(string)
            while pointer.pointee != 0 {
                pointer = pointer.advanced(by: 1)
            }
            pointer = pointer.advanced(by: 1)
            guard pointer.pointee != 0 else { break }
        }
        self = strings
    }
}

