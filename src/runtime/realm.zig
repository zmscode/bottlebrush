//! Realm bootstrap: installs every intrinsic (constructors, prototypes,
//! globals) onto a fresh Vm. Split out of the interpreter so builtin
//! registration lives beside the builtins themselves.

const std = @import("std");
const gc = @import("../gc.zig");
const bc = @import("../bytecode.zig");
const bilby = @import("bilby");
const Value = @import("../value.zig").Value;
const interpreter = @import("../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;
const asCtor = Vm.asCtor;

const array_mod = @import("builtins/array.zig");
const nativeArrayAt = array_mod.nativeArrayAt;
const nativeArrayShift = array_mod.nativeArrayShift;
const nativeArrayUnshift = array_mod.nativeArrayUnshift;
const nativeArrayReverse = array_mod.nativeArrayReverse;
const nativeArrayFill = array_mod.nativeArrayFill;
const nativeArrayLastIndexOf = array_mod.nativeArrayLastIndexOf;
const nativeArraySome = array_mod.nativeArraySome;
const nativeArrayEvery = array_mod.nativeArrayEvery;
const nativeArrayFind = array_mod.nativeArrayFind;
const nativeArrayFindIndex = array_mod.nativeArrayFindIndex;
const nativeArrayFindLast = array_mod.nativeArrayFindLast;
const nativeArrayFindLastIndex = array_mod.nativeArrayFindLastIndex;
const nativeArrayReduce = array_mod.nativeArrayReduce;
const nativeArrayReduceRight = array_mod.nativeArrayReduceRight;
const nativeArraySplice = array_mod.nativeArraySplice;
const nativeArraySort = array_mod.nativeArraySort;
const nativeArrayCopyWithin = array_mod.nativeArrayCopyWithin;
const nativeArrayFlat = array_mod.nativeArrayFlat;
const nativeArrayFlatMap = array_mod.nativeArrayFlatMap;
const nativeArrayOf = array_mod.nativeArrayOf;
const nativeArrayFrom = array_mod.nativeArrayFrom;
const nativeArray = array_mod.nativeArray;
const nativeArrayConcat = array_mod.nativeArrayConcat;
const nativeArrayFilter = array_mod.nativeArrayFilter;
const nativeArrayForEach = array_mod.nativeArrayForEach;
const nativeArrayIncludes = array_mod.nativeArrayIncludes;
const nativeArrayIndexOf = array_mod.nativeArrayIndexOf;
const nativeArrayIsArray = array_mod.nativeArrayIsArray;
const nativeArrayJoin = array_mod.nativeArrayJoin;
const nativeArrayMap = array_mod.nativeArrayMap;
const nativeArrayPop = array_mod.nativeArrayPop;
const nativeArrayPush = array_mod.nativeArrayPush;
const nativeArraySlice = array_mod.nativeArraySlice;
const nativeArrayToString = array_mod.nativeArrayToString;

const collections_mod = @import("builtins/collections.zig");
const nativeCollectionClear = collections_mod.nativeCollectionClear;
const nativeMap = collections_mod.nativeMap;
const nativeMapDelete = collections_mod.nativeMapDelete;
const nativeMapForEach = collections_mod.nativeMapForEach;
const nativeMapGet = collections_mod.nativeMapGet;
const nativeMapHas = collections_mod.nativeMapHas;
const nativeMapSet = collections_mod.nativeMapSet;
const nativeMapSize = collections_mod.nativeMapSize;
const nativeSet = collections_mod.nativeSet;
const nativeSetAdd = collections_mod.nativeSetAdd;
const nativeWeakMap = collections_mod.nativeWeakMap;
const nativeWeakMapGet = collections_mod.nativeWeakMapGet;
const nativeWeakMapSet = collections_mod.nativeWeakMapSet;
const nativeWeakMapHas = collections_mod.nativeWeakMapHas;
const nativeWeakMapDelete = collections_mod.nativeWeakMapDelete;
const nativeWeakSet = collections_mod.nativeWeakSet;
const nativeWeakSetAdd = collections_mod.nativeWeakSetAdd;
const nativeWeakSetHas = collections_mod.nativeWeakSetHas;
const nativeWeakSetDelete = collections_mod.nativeWeakSetDelete;
const nativeWeakRef = collections_mod.nativeWeakRef;
const nativeWeakRefDeref = collections_mod.nativeWeakRefDeref;
const nativeSetDelete = collections_mod.nativeSetDelete;
const nativeSetForEach = collections_mod.nativeSetForEach;
const nativeSetHas = collections_mod.nativeSetHas;
const nativeSetSize = collections_mod.nativeSetSize;

const date_mod = @import("builtins/date.zig");
const nativeDate = date_mod.nativeDate;
const nativeDateGetDate = date_mod.nativeDateGetDate;
const nativeDateGetDay = date_mod.nativeDateGetDay;
const nativeDateGetFullYear = date_mod.nativeDateGetFullYear;
const nativeDateGetHours = date_mod.nativeDateGetHours;
const nativeDateGetMinutes = date_mod.nativeDateGetMinutes;
const nativeDateGetMonth = date_mod.nativeDateGetMonth;
const nativeDateGetMs = date_mod.nativeDateGetMs;
const nativeDateGetSeconds = date_mod.nativeDateGetSeconds;
const nativeDateGetTime = date_mod.nativeDateGetTime;
const nativeDateGetTimezoneOffset = date_mod.nativeDateGetTimezoneOffset;
const nativeDateNow = date_mod.nativeDateNow;
const nativeDateParse = date_mod.nativeDateParse;
const nativeDateSetDate = date_mod.nativeDateSetDate;
const nativeDateSetFullYear = date_mod.nativeDateSetFullYear;
const nativeDateSetHours = date_mod.nativeDateSetHours;
const nativeDateSetMilliseconds = date_mod.nativeDateSetMilliseconds;
const nativeDateSetMinutes = date_mod.nativeDateSetMinutes;
const nativeDateSetMonth = date_mod.nativeDateSetMonth;
const nativeDateSetSeconds = date_mod.nativeDateSetSeconds;
const nativeDateSetTime = date_mod.nativeDateSetTime;
const nativeDateToDateString = date_mod.nativeDateToDateString;
const nativeDateToISOString = date_mod.nativeDateToISOString;
const nativeDateToTimeString = date_mod.nativeDateToTimeString;
const nativeDateToUTCString = date_mod.nativeDateToUTCString;
const nativeDateUTC = date_mod.nativeDateUTC;

const errors_mod = @import("builtins/errors.zig");
const nativeError = errors_mod.nativeError;
const nativeErrorToString = errors_mod.nativeErrorToString;

const function_mod = @import("builtins/function.zig");
const nativeEval = function_mod.nativeEval;
const nativeFunctionApply = function_mod.nativeFunctionApply;
const nativeFunctionBind = function_mod.nativeFunctionBind;
const nativeFunctionCall = function_mod.nativeFunctionCall;
const nativeFunctionCtor = function_mod.nativeFunctionCtor;
const nativeFunctionToString = function_mod.nativeFunctionToString;

const global_mod = @import("builtins/global.zig");
const nativeConsoleLog = global_mod.nativeConsoleLog;
const nativeConsoleError = global_mod.nativeConsoleError;
const nativeDecodeURIComponent = global_mod.nativeDecodeURIComponent;
const nativeEncodeURI = global_mod.nativeEncodeURI;
const nativeEncodeURIComponent = global_mod.nativeEncodeURIComponent;
const nativeIsFinite = global_mod.nativeIsFinite;
const nativeIsNaN = global_mod.nativeIsNaN;
const nativeParseFloat = global_mod.nativeParseFloat;
const nativeParseInt = global_mod.nativeParseInt;

const iterator_mod = @import("builtins/iterator.zig");
const nativeGeneratorNext = iterator_mod.nativeGeneratorNext;
const nativeGeneratorReturn = iterator_mod.nativeGeneratorReturn;
const nativeGeneratorThrow = iterator_mod.nativeGeneratorThrow;
const nativeIterSelf = iterator_mod.nativeIterSelf;
const nativeIterableEntries = iterator_mod.nativeIterableEntries;
const nativeIterableKeys = iterator_mod.nativeIterableKeys;
const nativeIterableValues = iterator_mod.nativeIterableValues;
const nativeIteratorNext = iterator_mod.nativeIteratorNext;

const json_mod = @import("builtins/json.zig");
const nativeJSONParse = json_mod.nativeJSONParse;
const nativeJSONStringify = json_mod.nativeJSONStringify;

const math_mod = @import("builtins/math.zig");
const mathUnaryFn = math_mod.mathUnaryFn;
const nativeMathAbs = math_mod.nativeMathAbs;
const nativeMathAtan2 = math_mod.nativeMathAtan2;
const nativeMathCeil = math_mod.nativeMathCeil;
const nativeMathClz32 = math_mod.nativeMathClz32;
const nativeMathFloor = math_mod.nativeMathFloor;
const nativeMathHypot = math_mod.nativeMathHypot;
const nativeMathImul = math_mod.nativeMathImul;
const nativeMathMax = math_mod.nativeMathMax;
const nativeMathMin = math_mod.nativeMathMin;
const nativeMathPow = math_mod.nativeMathPow;
const nativeMathRandom = math_mod.nativeMathRandom;
const nativeMathRound = math_mod.nativeMathRound;
const nativeMathSign = math_mod.nativeMathSign;
const nativeMathSqrt = math_mod.nativeMathSqrt;
const nativeMathTrunc = math_mod.nativeMathTrunc;
const opAcos = math_mod.opAcos;
const opAcosh = math_mod.opAcosh;
const opAsin = math_mod.opAsin;
const opAsinh = math_mod.opAsinh;
const opAtan = math_mod.opAtan;
const opAtanh = math_mod.opAtanh;
const opCbrt = math_mod.opCbrt;
const opCos = math_mod.opCos;
const opCosh = math_mod.opCosh;
const opExp = math_mod.opExp;
const opExpm1 = math_mod.opExpm1;
const opFround = math_mod.opFround;
const opLog = math_mod.opLog;
const opLog10 = math_mod.opLog10;
const opLog1p = math_mod.opLog1p;
const opLog2 = math_mod.opLog2;
const opSin = math_mod.opSin;
const opSinh = math_mod.opSinh;
const opTan = math_mod.opTan;
const opTanh = math_mod.opTanh;

const meta_mod = @import("builtins/meta.zig");
const nativeProxy = meta_mod.nativeProxy;
const nativeProxyRevocable = meta_mod.nativeProxyRevocable;
const nativeReflectApply = meta_mod.nativeReflectApply;
const nativeReflectConstruct = meta_mod.nativeReflectConstruct;
const nativeReflectDelete = meta_mod.nativeReflectDelete;
const nativeReflectGet = meta_mod.nativeReflectGet;
const nativeReflectGetProto = meta_mod.nativeReflectGetProto;
const nativeReflectHas = meta_mod.nativeReflectHas;
const nativeReflectOwnKeys = meta_mod.nativeReflectOwnKeys;
const nativeReflectSet = meta_mod.nativeReflectSet;
const nativeSymbol = meta_mod.nativeSymbol;
const nativeSymbolDescription = meta_mod.nativeSymbolDescription;
const nativeSymbolFor = meta_mod.nativeSymbolFor;
const nativeSymbolKeyFor = meta_mod.nativeSymbolKeyFor;
const nativeSymbolToString = meta_mod.nativeSymbolToString;
const nativeSymbolValueOf = meta_mod.nativeSymbolValueOf;

const number_mod = @import("builtins/number.zig");
const nativeBoolean = number_mod.nativeBoolean;
const nativeBooleanToString = number_mod.nativeBooleanToString;
const nativeBooleanValueOf = number_mod.nativeBooleanValueOf;
const nativeNumber = number_mod.nativeNumber;
const nativeNumberIsFinite = number_mod.nativeNumberIsFinite;
const nativeNumberIsInteger = number_mod.nativeNumberIsInteger;
const nativeNumberIsNaN = number_mod.nativeNumberIsNaN;
const nativeNumberToExponential = number_mod.nativeNumberToExponential;
const nativeNumberToFixed = number_mod.nativeNumberToFixed;
const nativeNumberToPrecision = number_mod.nativeNumberToPrecision;
const nativeNumberToString = number_mod.nativeNumberToString;
const nativeNumberValueOf = number_mod.nativeNumberValueOf;

const object_mod = @import("builtins/object.zig");
const nativeHasOwnProperty = object_mod.nativeHasOwnProperty;
const nativeObjectSetPrototypeOf = object_mod.nativeObjectSetPrototypeOf;
const nativeProtoGetter = object_mod.nativeProtoGetter;
const nativeProtoSetter = object_mod.nativeProtoSetter;
const nativeObjectAssign = object_mod.nativeObjectAssign;
const nativeObjectIs = object_mod.nativeObjectIs;
const nativeObjectHasOwn = object_mod.nativeObjectHasOwn;
const nativeObjectFromEntries = object_mod.nativeObjectFromEntries;
const nativeObjectGetOwnPropertyDescriptors = object_mod.nativeObjectGetOwnPropertyDescriptors;
const nativeIsPrototypeOf = object_mod.nativeIsPrototypeOf;
const nativeObject = object_mod.nativeObject;
const nativeObjectCreate = object_mod.nativeObjectCreate;
const nativeObjectDefineProperties = object_mod.nativeObjectDefineProperties;
const nativeObjectDefineProperty = object_mod.nativeObjectDefineProperty;
const nativeObjectEntries = object_mod.nativeObjectEntries;
const nativeObjectFreeze = object_mod.nativeObjectFreeze;
const nativeObjectGetOwnPropertyDescriptor = object_mod.nativeObjectGetOwnPropertyDescriptor;
const nativeObjectGetOwnPropertyNames = object_mod.nativeObjectGetOwnPropertyNames;
const nativeObjectGetPrototypeOf = object_mod.nativeObjectGetPrototypeOf;
const nativeObjectIsExtensible = object_mod.nativeObjectIsExtensible;
const nativeObjectIsFrozen = object_mod.nativeObjectIsFrozen;
const nativeObjectIsSealed = object_mod.nativeObjectIsSealed;
const nativeObjectKeys = object_mod.nativeObjectKeys;
const nativeObjectPreventExtensions = object_mod.nativeObjectPreventExtensions;
const nativeObjectSeal = object_mod.nativeObjectSeal;
const nativeObjectToLocaleString = object_mod.nativeObjectToLocaleString;
const nativeObjectToString = object_mod.nativeObjectToString;
const nativeObjectValueOf = object_mod.nativeObjectValueOf;
const nativeObjectValues = object_mod.nativeObjectValues;
const nativePropertyIsEnumerable = object_mod.nativePropertyIsEnumerable;

const regexp_mod = @import("builtins/regexp.zig");
const nativeRegExp = regexp_mod.nativeRegExp;
const nativeRegExpExec = regexp_mod.nativeRegExpExec;
const nativeRegExpGetFlags = regexp_mod.nativeRegExpGetFlags;
const nativeRegExpGetSource = regexp_mod.nativeRegExpGetSource;
const nativeRegExpTest = regexp_mod.nativeRegExpTest;
const nativeRegExpToString = regexp_mod.nativeRegExpToString;
const regexpFlagGetter = regexp_mod.regexpFlagGetter;

const string_mod = @import("builtins/string.zig");
const nativeStringAt = string_mod.nativeStringAt;
const nativeStringPadStart = string_mod.nativeStringPadStart;
const nativeStringPadEnd = string_mod.nativeStringPadEnd;
const nativeStringCodePointAt = string_mod.nativeStringCodePointAt;
const nativeStringFromCodePoint = string_mod.nativeStringFromCodePoint;
const nativeStringSubstr = string_mod.nativeStringSubstr;
const nativeStringTrimStart = string_mod.nativeStringTrimStart;
const nativeStringTrimEnd = string_mod.nativeStringTrimEnd;
const nativeStringReplaceAll = string_mod.nativeStringReplaceAll;
const bigint_mod = @import("builtins/bigint.zig");
const nativeBigInt = bigint_mod.nativeBigInt;
const nativeBigIntToString = bigint_mod.nativeBigIntToString;
const nativeBigIntValueOf = bigint_mod.nativeBigIntValueOf;
const nativeBigIntAsIntN = bigint_mod.nativeBigIntAsIntN;
const nativeBigIntAsUintN = bigint_mod.nativeBigIntAsUintN;
const nativeRegExpSymbolMatch = string_mod.nativeRegExpSymbolMatch;
const nativeRegExpSymbolReplace = string_mod.nativeRegExpSymbolReplace;
const nativeRegExpSymbolSearch = string_mod.nativeRegExpSymbolSearch;
const nativeRegExpSymbolSplit = string_mod.nativeRegExpSymbolSplit;
const nativeString = string_mod.nativeString;
const nativeStringCharAt = string_mod.nativeStringCharAt;
const nativeStringCharCodeAt = string_mod.nativeStringCharCodeAt;
const nativeStringConcat = string_mod.nativeStringConcat;
const nativeStringEndsWith = string_mod.nativeStringEndsWith;
const nativeStringFromCharCode = string_mod.nativeStringFromCharCode;
const nativeStringIncludes = string_mod.nativeStringIncludes;
const nativeStringIndexOf = string_mod.nativeStringIndexOf;
const nativeStringLastIndexOf = string_mod.nativeStringLastIndexOf;
const nativeStringLocaleCompare = string_mod.nativeStringLocaleCompare;
const nativeStringMatch = string_mod.nativeStringMatch;
const nativeStringRepeat = string_mod.nativeStringRepeat;
const nativeStringReplace = string_mod.nativeStringReplace;
const nativeStringSearch = string_mod.nativeStringSearch;
const nativeStringSlice = string_mod.nativeStringSlice;
const nativeStringSplit = string_mod.nativeStringSplit;
const nativeStringStartsWith = string_mod.nativeStringStartsWith;
const nativeStringSubstring = string_mod.nativeStringSubstring;
const nativeStringToLowerCase = string_mod.nativeStringToLowerCase;
const nativeStringToString = string_mod.nativeStringToString;
const nativeStringToUpperCase = string_mod.nativeStringToUpperCase;
const nativeStringTrim = string_mod.nativeStringTrim;

const typedarray_mod = @import("builtins/typedarray.zig");
const dataViewGet = typedarray_mod.dataViewGet;
const dataViewSet = typedarray_mod.dataViewSet;
const nativeArrayBuffer = typedarray_mod.nativeArrayBuffer;
const nativeDataView = typedarray_mod.nativeDataView;
const nativeTAFill = typedarray_mod.nativeTAFill;
const nativeTAForEach = typedarray_mod.nativeTAForEach;
const nativeTAIndexOf = typedarray_mod.nativeTAIndexOf;
const nativeTAJoin = typedarray_mod.nativeTAJoin;
const nativeTASet = typedarray_mod.nativeTASet;
const nativeTASubarray = typedarray_mod.nativeTASubarray;
const typedArrayConstructor = typedarray_mod.typedArrayConstructor;

pub fn installBuiltins(vm: *Vm) Error!void {
    const global = vm.global_object.?;

    // ---- @@iterator + %IteratorPrototype% (iterables below reference it) ----
    const sym_iter = try vm.makeSymbol("Symbol.iterator");
    vm.symbol_iterator = sym_iter;
    vm.symbol_iterator_key = try vm.toPropertyKey(sym_iter);
    const iter_proto = try vm.newObject(vm.object_proto);
    vm.iterator_proto = iter_proto;
    try vm.defineMethod(iter_proto, "next", nativeIteratorNext, 0);
    try vm.defineData(iter_proto, vm.symbol_iterator_key, Value.fromObject(try vm.makeNative("[Symbol.iterator]", nativeIterSelf, 0)), true, false, true);

    // %GeneratorPrototype% inherits %IteratorPrototype% (so generators are iterable).
    const gen_proto = try vm.newObject(vm.iterator_proto);
    vm.generator_proto = gen_proto;
    try vm.defineMethod(gen_proto, "next", nativeGeneratorNext, 1);
    try vm.defineMethod(gen_proto, "return", nativeGeneratorReturn, 1);
    try vm.defineMethod(gen_proto, "throw", nativeGeneratorThrow, 1);

    // ---- Function.prototype methods + Function constructor ----
    const fn_proto = vm.function_proto.?;
    try vm.defineMethod(fn_proto, "call", nativeFunctionCall, 1);
    try vm.defineMethod(fn_proto, "apply", nativeFunctionApply, 2);
    try vm.defineMethod(fn_proto, "bind", nativeFunctionBind, 1);
    try vm.defineMethod(fn_proto, "toString", nativeFunctionToString, 0);
    const function_ctor = asCtor(try vm.makeNative("Function", nativeFunctionCtor, 1));
    try vm.defineData(function_ctor, "prototype", Value.fromObject(fn_proto), false, false, false);
    try vm.defineData(fn_proto, "constructor", Value.fromObject(function_ctor), true, false, true);
    try vm.defineData(global, "Function", Value.fromObject(function_ctor), true, false, true);

    // ---- Object.prototype methods + Object constructor ----
    try vm.defineMethod(vm.object_proto.?, "hasOwnProperty", nativeHasOwnProperty, 1);
    try vm.defineMethod(vm.object_proto.?, "toString", nativeObjectToString, 0);
    try vm.defineMethod(vm.object_proto.?, "valueOf", nativeObjectValueOf, 0);
    try vm.defineMethod(vm.object_proto.?, "isPrototypeOf", nativeIsPrototypeOf, 1);
    try vm.defineMethod(vm.object_proto.?, "propertyIsEnumerable", nativePropertyIsEnumerable, 1);
    try vm.defineMethod(vm.object_proto.?, "toLocaleString", nativeObjectToLocaleString, 0);
    try vm.defineAccessor(vm.object_proto.?, "__proto__", nativeProtoGetter, nativeProtoSetter);

    const object_ctor = asCtor(try vm.makeNative("Object", nativeObject, 1));
    try vm.defineData(object_ctor, "prototype", Value.fromObject(vm.object_proto.?), false, false, false);
    try vm.defineData(vm.object_proto.?, "constructor", Value.fromObject(object_ctor), true, false, true);
    try vm.defineMethod(object_ctor, "keys", nativeObjectKeys, 1);
    try vm.defineMethod(object_ctor, "values", nativeObjectValues, 1);
    try vm.defineMethod(object_ctor, "entries", nativeObjectEntries, 1);
    try vm.defineMethod(object_ctor, "getPrototypeOf", nativeObjectGetPrototypeOf, 1);
    try vm.defineMethod(object_ctor, "create", nativeObjectCreate, 2);
    try vm.defineMethod(object_ctor, "defineProperty", nativeObjectDefineProperty, 3);
    try vm.defineMethod(object_ctor, "getOwnPropertyDescriptor", nativeObjectGetOwnPropertyDescriptor, 2);
    try vm.defineMethod(object_ctor, "getOwnPropertyNames", nativeObjectGetOwnPropertyNames, 1);
    try vm.defineMethod(object_ctor, "setPrototypeOf", nativeObjectSetPrototypeOf, 2);
    try vm.defineMethod(object_ctor, "assign", nativeObjectAssign, 2);
    try vm.defineMethod(object_ctor, "is", nativeObjectIs, 2);
    try vm.defineMethod(object_ctor, "hasOwn", nativeObjectHasOwn, 2);
    try vm.defineMethod(object_ctor, "fromEntries", nativeObjectFromEntries, 1);
    try vm.defineMethod(object_ctor, "getOwnPropertyDescriptors", nativeObjectGetOwnPropertyDescriptors, 1);
    try vm.defineMethod(object_ctor, "defineProperties", nativeObjectDefineProperties, 2);
    try vm.defineMethod(object_ctor, "freeze", nativeObjectFreeze, 1);
    try vm.defineMethod(object_ctor, "isFrozen", nativeObjectIsFrozen, 1);
    try vm.defineMethod(object_ctor, "seal", nativeObjectSeal, 1);
    try vm.defineMethod(object_ctor, "isSealed", nativeObjectIsSealed, 1);
    try vm.defineMethod(object_ctor, "preventExtensions", nativeObjectPreventExtensions, 1);
    try vm.defineMethod(object_ctor, "isExtensible", nativeObjectIsExtensible, 1);
    try vm.defineData(global, "Object", Value.fromObject(object_ctor), true, false, true);

    // ---- Error hierarchy ----
    const error_proto = try vm.newObject(vm.object_proto);
    vm.error_proto = error_proto;
    try vm.defineData(error_proto, "name", try vm.makeString("Error"), true, false, true);
    try vm.defineData(error_proto, "message", try vm.makeString(""), true, false, true);
    try vm.defineMethod(error_proto, "toString", nativeErrorToString, 0);
    const error_ctor = asCtor(try vm.makeNative("Error", nativeError, 1));
    try vm.defineData(error_ctor, "prototype", Value.fromObject(error_proto), false, false, false);
    try vm.defineData(error_proto, "constructor", Value.fromObject(error_ctor), true, false, true);
    try vm.defineData(global, "Error", Value.fromObject(error_ctor), true, false, true);

    vm.type_error_proto = try vm.installErrorSubtype("TypeError");
    vm.range_error_proto = try vm.installErrorSubtype("RangeError");
    vm.reference_error_proto = try vm.installErrorSubtype("ReferenceError");
    vm.syntax_error_proto = try vm.installErrorSubtype("SyntaxError");
    _ = try vm.installErrorSubtype("EvalError");
    _ = try vm.installErrorSubtype("URIError");

    // ---- Array ----
    const array_proto = try vm.heap.create(gc.Object);
    array_proto.prototype = vm.object_proto;
    array_proto.is_array = true; // Array.prototype is itself an (empty) array
    vm.array_proto = array_proto;
    try vm.defineMethod(array_proto, "push", nativeArrayPush, 1);
    try vm.defineMethod(array_proto, "pop", nativeArrayPop, 0);
    try vm.defineMethod(array_proto, "indexOf", nativeArrayIndexOf, 1);
    try vm.defineMethod(array_proto, "includes", nativeArrayIncludes, 1);
    try vm.defineMethod(array_proto, "join", nativeArrayJoin, 1);
    try vm.defineMethod(array_proto, "slice", nativeArraySlice, 2);
    try vm.defineMethod(array_proto, "concat", nativeArrayConcat, 1);
    try vm.defineMethod(array_proto, "forEach", nativeArrayForEach, 1);
    try vm.defineMethod(array_proto, "map", nativeArrayMap, 1);
    try vm.defineMethod(array_proto, "filter", nativeArrayFilter, 1);
    try vm.defineMethod(array_proto, "at", nativeArrayAt, 1);
    try vm.defineMethod(array_proto, "shift", nativeArrayShift, 0);
    try vm.defineMethod(array_proto, "unshift", nativeArrayUnshift, 1);
    try vm.defineMethod(array_proto, "reverse", nativeArrayReverse, 0);
    try vm.defineMethod(array_proto, "fill", nativeArrayFill, 1);
    try vm.defineMethod(array_proto, "lastIndexOf", nativeArrayLastIndexOf, 1);
    try vm.defineMethod(array_proto, "some", nativeArraySome, 1);
    try vm.defineMethod(array_proto, "every", nativeArrayEvery, 1);
    try vm.defineMethod(array_proto, "find", nativeArrayFind, 1);
    try vm.defineMethod(array_proto, "findIndex", nativeArrayFindIndex, 1);
    try vm.defineMethod(array_proto, "findLast", nativeArrayFindLast, 1);
    try vm.defineMethod(array_proto, "findLastIndex", nativeArrayFindLastIndex, 1);
    try vm.defineMethod(array_proto, "reduce", nativeArrayReduce, 1);
    try vm.defineMethod(array_proto, "reduceRight", nativeArrayReduceRight, 1);
    try vm.defineMethod(array_proto, "splice", nativeArraySplice, 2);
    try vm.defineMethod(array_proto, "sort", nativeArraySort, 1);
    try vm.defineMethod(array_proto, "copyWithin", nativeArrayCopyWithin, 2);
    try vm.defineMethod(array_proto, "flat", nativeArrayFlat, 0);
    try vm.defineMethod(array_proto, "flatMap", nativeArrayFlatMap, 1);
    try vm.defineMethod(array_proto, "values", nativeIterableValues, 0);
    try vm.defineMethod(array_proto, "keys", nativeIterableKeys, 0);
    try vm.defineMethod(array_proto, "entries", nativeIterableEntries, 0);
    try vm.defineData(array_proto, vm.symbol_iterator_key, Value.fromObject(try vm.makeNative("values", nativeIterableValues, 0)), true, false, true);
    try vm.defineMethod(array_proto, "toString", nativeArrayToString, 0);
    const array_ctor = asCtor(try vm.makeNative("Array", nativeArray, 1));
    try vm.defineData(array_ctor, "prototype", Value.fromObject(array_proto), false, false, false);
    try vm.defineData(array_proto, "constructor", Value.fromObject(array_ctor), true, false, true);
    try vm.defineMethod(array_ctor, "isArray", nativeArrayIsArray, 1);
    try vm.defineMethod(array_ctor, "of", nativeArrayOf, 0);
    try vm.defineMethod(array_ctor, "from", nativeArrayFrom, 1);
    try vm.defineData(global, "Array", Value.fromObject(array_ctor), true, false, true);

    // ---- String (+ prototype methods for primitive strings) ----
    const string_proto = try vm.newObject(vm.object_proto);
    vm.string_proto = string_proto;
    try vm.defineMethod(string_proto, "charAt", nativeStringCharAt, 1);
    try vm.defineMethod(string_proto, "charCodeAt", nativeStringCharCodeAt, 1);
    try vm.defineMethod(string_proto, "indexOf", nativeStringIndexOf, 1);
    try vm.defineMethod(string_proto, "includes", nativeStringIncludes, 1);
    try vm.defineMethod(string_proto, "startsWith", nativeStringStartsWith, 1);
    try vm.defineMethod(string_proto, "endsWith", nativeStringEndsWith, 1);
    try vm.defineMethod(string_proto, "slice", nativeStringSlice, 2);
    try vm.defineMethod(string_proto, "substring", nativeStringSubstring, 2);
    try vm.defineMethod(string_proto, "toUpperCase", nativeStringToUpperCase, 0);
    try vm.defineMethod(string_proto, "toLowerCase", nativeStringToLowerCase, 0);
    try vm.defineMethod(string_proto, "trim", nativeStringTrim, 0);
    try vm.defineMethod(string_proto, "repeat", nativeStringRepeat, 1);
    try vm.defineMethod(string_proto, "concat", nativeStringConcat, 1);
    try vm.defineMethod(string_proto, "split", nativeStringSplit, 2);
    try vm.defineMethod(string_proto, "match", nativeStringMatch, 1);
    try vm.defineMethod(string_proto, "search", nativeStringSearch, 1);
    try vm.defineMethod(string_proto, "replace", nativeStringReplace, 2);
    try vm.defineMethod(string_proto, "lastIndexOf", nativeStringLastIndexOf, 1);
    try vm.defineMethod(string_proto, "localeCompare", nativeStringLocaleCompare, 1);
    try vm.defineMethod(string_proto, "toLocaleLowerCase", nativeStringToLowerCase, 0);
    try vm.defineMethod(string_proto, "toLocaleUpperCase", nativeStringToUpperCase, 0);
    try vm.defineMethod(string_proto, "at", nativeStringAt, 1);
    try vm.defineMethod(string_proto, "padStart", nativeStringPadStart, 1);
    try vm.defineMethod(string_proto, "padEnd", nativeStringPadEnd, 1);
    try vm.defineMethod(string_proto, "codePointAt", nativeStringCodePointAt, 1);
    try vm.defineMethod(string_proto, "substr", nativeStringSubstr, 2);
    try vm.defineMethod(string_proto, "trimStart", nativeStringTrimStart, 0);
    try vm.defineMethod(string_proto, "trimEnd", nativeStringTrimEnd, 0);
    try vm.defineMethod(string_proto, "replaceAll", nativeStringReplaceAll, 2);
    try vm.defineData(string_proto, vm.symbol_iterator_key, Value.fromObject(try vm.makeNative("[Symbol.iterator]", nativeIterableValues, 0)), true, false, true);
    try vm.defineMethod(string_proto, "toString", nativeStringToString, 0);
    try vm.defineMethod(string_proto, "valueOf", nativeStringToString, 0);
    const string_ctor = asCtor(try vm.makeNative("String", nativeString, 1));
    try vm.defineData(string_ctor, "prototype", Value.fromObject(string_proto), false, false, false);
    try vm.defineData(string_proto, "constructor", Value.fromObject(string_ctor), true, false, true);
    try vm.defineMethod(string_ctor, "fromCharCode", nativeStringFromCharCode, 1);
    try vm.defineMethod(string_ctor, "fromCodePoint", nativeStringFromCodePoint, 1);
    try vm.defineData(global, "String", Value.fromObject(string_ctor), true, false, true);

    // ---- Number (+ prototype) / Boolean ----
    const number_proto = try vm.newObject(vm.object_proto);
    vm.number_proto = number_proto;
    try vm.defineMethod(number_proto, "toFixed", nativeNumberToFixed, 1);
    try vm.defineMethod(number_proto, "toString", nativeNumberToString, 1);
    try vm.defineMethod(number_proto, "valueOf", nativeNumberValueOf, 0);
    try vm.defineMethod(number_proto, "toExponential", nativeNumberToExponential, 1);
    try vm.defineMethod(number_proto, "toPrecision", nativeNumberToPrecision, 1);
    try vm.defineMethod(number_proto, "toLocaleString", nativeNumberToString, 0);
    const number_ctor = asCtor(try vm.makeNative("Number", nativeNumber, 1));
    try vm.defineData(number_ctor, "prototype", Value.fromObject(number_proto), false, false, false);
    try vm.defineData(number_proto, "constructor", Value.fromObject(number_ctor), true, false, true);
    try vm.defineData(number_ctor, "MAX_SAFE_INTEGER", Value.fromNumber(9007199254740991), false, false, false);
    try vm.defineData(number_ctor, "MIN_SAFE_INTEGER", Value.fromNumber(-9007199254740991), false, false, false);
    try vm.defineData(number_ctor, "POSITIVE_INFINITY", Value.fromNumber(std.math.inf(f64)), false, false, false);
    try vm.defineData(number_ctor, "NEGATIVE_INFINITY", Value.fromNumber(-std.math.inf(f64)), false, false, false);
    try vm.defineData(number_ctor, "NaN", Value.fromNumber(std.math.nan(f64)), false, false, false);
    try vm.defineData(number_ctor, "MAX_VALUE", Value.fromNumber(1.7976931348623157e308), false, false, false);
    try vm.defineData(number_ctor, "MIN_VALUE", Value.fromNumber(5e-324), false, false, false);
    try vm.defineData(number_ctor, "EPSILON", Value.fromNumber(2.220446049250313e-16), false, false, false);
    try vm.defineMethod(number_ctor, "isInteger", nativeNumberIsInteger, 1);
    try vm.defineMethod(number_ctor, "isFinite", nativeNumberIsFinite, 1);
    try vm.defineMethod(number_ctor, "isNaN", nativeNumberIsNaN, 1);
    try vm.defineData(global, "Number", Value.fromObject(number_ctor), true, false, true);

    const boolean_proto = try vm.newObject(vm.object_proto);
    vm.boolean_proto = boolean_proto;
    try vm.defineMethod(boolean_proto, "toString", nativeBooleanToString, 0);
    try vm.defineMethod(boolean_proto, "valueOf", nativeBooleanValueOf, 0);
    const boolean_ctor = asCtor(try vm.makeNative("Boolean", nativeBoolean, 1));
    try vm.defineData(boolean_ctor, "prototype", Value.fromObject(boolean_proto), false, false, false);
    try vm.defineData(boolean_proto, "constructor", Value.fromObject(boolean_ctor), true, false, true);
    try vm.defineData(global, "Boolean", Value.fromObject(boolean_ctor), true, false, true);

    // ---- Math ----
    const math = try vm.newObject(vm.object_proto);
    try vm.defineData(math, "PI", Value.fromNumber(std.math.pi), false, false, false);
    try vm.defineData(math, "E", Value.fromNumber(std.math.e), false, false, false);
    try vm.defineMethod(math, "abs", nativeMathAbs, 1);
    try vm.defineMethod(math, "floor", nativeMathFloor, 1);
    try vm.defineMethod(math, "ceil", nativeMathCeil, 1);
    try vm.defineMethod(math, "round", nativeMathRound, 1);
    try vm.defineMethod(math, "trunc", nativeMathTrunc, 1);
    try vm.defineMethod(math, "sqrt", nativeMathSqrt, 1);
    try vm.defineMethod(math, "sign", nativeMathSign, 1);
    try vm.defineMethod(math, "max", nativeMathMax, 2);
    try vm.defineMethod(math, "min", nativeMathMin, 2);
    try vm.defineMethod(math, "pow", nativeMathPow, 2);
    try vm.defineMethod(math, "sin", mathUnaryFn(opSin), 1);
    try vm.defineMethod(math, "cos", mathUnaryFn(opCos), 1);
    try vm.defineMethod(math, "tan", mathUnaryFn(opTan), 1);
    try vm.defineMethod(math, "asin", mathUnaryFn(opAsin), 1);
    try vm.defineMethod(math, "acos", mathUnaryFn(opAcos), 1);
    try vm.defineMethod(math, "atan", mathUnaryFn(opAtan), 1);
    try vm.defineMethod(math, "sinh", mathUnaryFn(opSinh), 1);
    try vm.defineMethod(math, "cosh", mathUnaryFn(opCosh), 1);
    try vm.defineMethod(math, "tanh", mathUnaryFn(opTanh), 1);
    try vm.defineMethod(math, "asinh", mathUnaryFn(opAsinh), 1);
    try vm.defineMethod(math, "acosh", mathUnaryFn(opAcosh), 1);
    try vm.defineMethod(math, "atanh", mathUnaryFn(opAtanh), 1);
    try vm.defineMethod(math, "exp", mathUnaryFn(opExp), 1);
    try vm.defineMethod(math, "expm1", mathUnaryFn(opExpm1), 1);
    try vm.defineMethod(math, "log", mathUnaryFn(opLog), 1);
    try vm.defineMethod(math, "log2", mathUnaryFn(opLog2), 1);
    try vm.defineMethod(math, "log10", mathUnaryFn(opLog10), 1);
    try vm.defineMethod(math, "log1p", mathUnaryFn(opLog1p), 1);
    try vm.defineMethod(math, "cbrt", mathUnaryFn(opCbrt), 1);
    try vm.defineMethod(math, "fround", mathUnaryFn(opFround), 1);
    try vm.defineMethod(math, "atan2", nativeMathAtan2, 2);
    try vm.defineMethod(math, "hypot", nativeMathHypot, 2);
    try vm.defineMethod(math, "clz32", nativeMathClz32, 1);
    try vm.defineMethod(math, "imul", nativeMathImul, 2);
    try vm.defineMethod(math, "random", nativeMathRandom, 0);
    try vm.defineData(math, "LN2", Value.fromNumber(0.6931471805599453), false, false, false);
    try vm.defineData(math, "LN10", Value.fromNumber(2.302585092994046), false, false, false);
    try vm.defineData(math, "LOG2E", Value.fromNumber(1.4426950408889634), false, false, false);
    try vm.defineData(math, "LOG10E", Value.fromNumber(0.4342944819032518), false, false, false);
    try vm.defineData(math, "SQRT2", Value.fromNumber(1.4142135623730951), false, false, false);
    try vm.defineData(math, "SQRT1_2", Value.fromNumber(0.7071067811865476), false, false, false);
    try vm.defineData(global, "Math", Value.fromObject(math), true, false, true);

    // ---- RegExp (matching powered by bilby) ----
    const regexp_proto = try vm.newObject(vm.object_proto);
    vm.regexp_proto = regexp_proto;
    try vm.defineMethod(regexp_proto, "test", nativeRegExpTest, 1);
    try vm.defineMethod(regexp_proto, "exec", nativeRegExpExec, 1);
    try vm.defineMethod(regexp_proto, "toString", nativeRegExpToString, 0);
    try vm.defineGetter(regexp_proto, "source", nativeRegExpGetSource);
    try vm.defineGetter(regexp_proto, "flags", nativeRegExpGetFlags);
    try vm.defineGetter(regexp_proto, "global", regexpFlagGetter("global"));
    try vm.defineGetter(regexp_proto, "ignoreCase", regexpFlagGetter("ignore_case"));
    try vm.defineGetter(regexp_proto, "multiline", regexpFlagGetter("multiline"));
    try vm.defineGetter(regexp_proto, "sticky", regexpFlagGetter("sticky"));
    try vm.defineGetter(regexp_proto, "dotAll", regexpFlagGetter("dot_all"));
    try vm.defineGetter(regexp_proto, "unicode", regexpFlagGetter("unicode"));
    const regexp_ctor = asCtor(try vm.makeNative("RegExp", nativeRegExp, 2));
    try vm.defineData(regexp_ctor, "prototype", Value.fromObject(regexp_proto), false, false, false);
    try vm.defineData(regexp_proto, "constructor", Value.fromObject(regexp_ctor), true, false, true);
    try vm.defineData(global, "RegExp", Value.fromObject(regexp_ctor), true, false, true);

    // ---- Map ----
    const map_proto = try vm.newObject(vm.object_proto);
    vm.map_proto = map_proto;
    try vm.defineMethod(map_proto, "get", nativeMapGet, 1);
    try vm.defineMethod(map_proto, "set", nativeMapSet, 2);
    try vm.defineMethod(map_proto, "has", nativeMapHas, 1);
    try vm.defineMethod(map_proto, "delete", nativeMapDelete, 1);
    try vm.defineMethod(map_proto, "clear", nativeCollectionClear, 0);
    try vm.defineMethod(map_proto, "forEach", nativeMapForEach, 1);
    try vm.defineMethod(map_proto, "entries", nativeIterableEntries, 0);
    try vm.defineMethod(map_proto, "keys", nativeIterableKeys, 0);
    try vm.defineMethod(map_proto, "values", nativeIterableValues, 0);
    try vm.defineData(map_proto, vm.symbol_iterator_key, Value.fromObject(try vm.makeNative("entries", nativeIterableEntries, 0)), true, false, true);
    try vm.defineGetter(map_proto, "size", nativeMapSize);
    const map_ctor = asCtor(try vm.makeNative("Map", nativeMap, 0));
    try vm.defineData(map_ctor, "prototype", Value.fromObject(map_proto), false, false, false);
    try vm.defineData(map_proto, "constructor", Value.fromObject(map_ctor), true, false, true);
    try vm.defineData(global, "Map", Value.fromObject(map_ctor), true, false, true);

    // ---- Set ----
    const set_proto = try vm.newObject(vm.object_proto);
    vm.set_proto = set_proto;
    try vm.defineMethod(set_proto, "add", nativeSetAdd, 1);
    try vm.defineMethod(set_proto, "has", nativeSetHas, 1);
    try vm.defineMethod(set_proto, "delete", nativeSetDelete, 1);
    try vm.defineMethod(set_proto, "clear", nativeCollectionClear, 0);
    try vm.defineMethod(set_proto, "forEach", nativeSetForEach, 1);
    try vm.defineMethod(set_proto, "values", nativeIterableValues, 0);
    try vm.defineMethod(set_proto, "keys", nativeIterableValues, 0);
    try vm.defineMethod(set_proto, "entries", nativeIterableEntries, 0);
    try vm.defineData(set_proto, vm.symbol_iterator_key, Value.fromObject(try vm.makeNative("values", nativeIterableValues, 0)), true, false, true);
    try vm.defineGetter(set_proto, "size", nativeSetSize);
    const set_ctor = asCtor(try vm.makeNative("Set", nativeSet, 0));
    try vm.defineData(set_ctor, "prototype", Value.fromObject(set_proto), false, false, false);
    try vm.defineData(set_proto, "constructor", Value.fromObject(set_ctor), true, false, true);
    try vm.defineData(global, "Set", Value.fromObject(set_ctor), true, false, true);

    // ---- WeakMap / WeakSet / WeakRef (GC ephemeron semantics) ----
    const weakmap_proto = try vm.newObject(vm.object_proto);
    try vm.defineMethod(weakmap_proto, "get", nativeWeakMapGet, 1);
    try vm.defineMethod(weakmap_proto, "set", nativeWeakMapSet, 2);
    try vm.defineMethod(weakmap_proto, "has", nativeWeakMapHas, 1);
    try vm.defineMethod(weakmap_proto, "delete", nativeWeakMapDelete, 1);
    const weakmap_ctor = asCtor(try vm.makeNative("WeakMap", nativeWeakMap, 0));
    try vm.defineData(weakmap_ctor, "prototype", Value.fromObject(weakmap_proto), false, false, false);
    try vm.defineData(weakmap_proto, "constructor", Value.fromObject(weakmap_ctor), true, false, true);
    try vm.defineData(global, "WeakMap", Value.fromObject(weakmap_ctor), true, false, true);

    const weakset_proto = try vm.newObject(vm.object_proto);
    try vm.defineMethod(weakset_proto, "add", nativeWeakSetAdd, 1);
    try vm.defineMethod(weakset_proto, "has", nativeWeakSetHas, 1);
    try vm.defineMethod(weakset_proto, "delete", nativeWeakSetDelete, 1);
    const weakset_ctor = asCtor(try vm.makeNative("WeakSet", nativeWeakSet, 0));
    try vm.defineData(weakset_ctor, "prototype", Value.fromObject(weakset_proto), false, false, false);
    try vm.defineData(weakset_proto, "constructor", Value.fromObject(weakset_ctor), true, false, true);
    try vm.defineData(global, "WeakSet", Value.fromObject(weakset_ctor), true, false, true);

    const weakref_proto = try vm.newObject(vm.object_proto);
    try vm.defineMethod(weakref_proto, "deref", nativeWeakRefDeref, 0);
    const weakref_ctor = asCtor(try vm.makeNative("WeakRef", nativeWeakRef, 1));
    try vm.defineData(weakref_ctor, "prototype", Value.fromObject(weakref_proto), false, false, false);
    try vm.defineData(weakref_proto, "constructor", Value.fromObject(weakref_ctor), true, false, true);
    try vm.defineData(global, "WeakRef", Value.fromObject(weakref_ctor), true, false, true);

    // ---- Date ----
    const date_proto = try vm.newObject(vm.object_proto);
    vm.date_proto = date_proto;
    try vm.defineMethod(date_proto, "getTime", nativeDateGetTime, 0);
    try vm.defineMethod(date_proto, "valueOf", nativeDateGetTime, 0);
    try vm.defineMethod(date_proto, "setTime", nativeDateSetTime, 1);
    try vm.defineMethod(date_proto, "getFullYear", nativeDateGetFullYear, 0);
    try vm.defineMethod(date_proto, "getUTCFullYear", nativeDateGetFullYear, 0);
    try vm.defineMethod(date_proto, "getMonth", nativeDateGetMonth, 0);
    try vm.defineMethod(date_proto, "getUTCMonth", nativeDateGetMonth, 0);
    try vm.defineMethod(date_proto, "getDate", nativeDateGetDate, 0);
    try vm.defineMethod(date_proto, "getUTCDate", nativeDateGetDate, 0);
    try vm.defineMethod(date_proto, "getDay", nativeDateGetDay, 0);
    try vm.defineMethod(date_proto, "getUTCDay", nativeDateGetDay, 0);
    try vm.defineMethod(date_proto, "getHours", nativeDateGetHours, 0);
    try vm.defineMethod(date_proto, "getUTCHours", nativeDateGetHours, 0);
    try vm.defineMethod(date_proto, "getMinutes", nativeDateGetMinutes, 0);
    try vm.defineMethod(date_proto, "getUTCMinutes", nativeDateGetMinutes, 0);
    try vm.defineMethod(date_proto, "getSeconds", nativeDateGetSeconds, 0);
    try vm.defineMethod(date_proto, "getUTCSeconds", nativeDateGetSeconds, 0);
    try vm.defineMethod(date_proto, "getMilliseconds", nativeDateGetMs, 0);
    try vm.defineMethod(date_proto, "toISOString", nativeDateToISOString, 0);
    try vm.defineMethod(date_proto, "toJSON", nativeDateToISOString, 1);
    try vm.defineMethod(date_proto, "toString", nativeDateToISOString, 0);
    try vm.defineMethod(date_proto, "getUTCMilliseconds", nativeDateGetMs, 0);
    try vm.defineMethod(date_proto, "getTimezoneOffset", nativeDateGetTimezoneOffset, 0);
    try vm.defineMethod(date_proto, "toDateString", nativeDateToDateString, 0);
    try vm.defineMethod(date_proto, "toTimeString", nativeDateToTimeString, 0);
    try vm.defineMethod(date_proto, "toUTCString", nativeDateToUTCString, 0);
    try vm.defineMethod(date_proto, "toLocaleString", nativeDateToISOString, 0);
    try vm.defineMethod(date_proto, "toLocaleDateString", nativeDateToDateString, 0);
    try vm.defineMethod(date_proto, "toLocaleTimeString", nativeDateToTimeString, 0);
    // Local time == UTC in this engine, so each setter serves both names.
    try vm.defineMethod(date_proto, "setFullYear", nativeDateSetFullYear, 3);
    try vm.defineMethod(date_proto, "setUTCFullYear", nativeDateSetFullYear, 3);
    try vm.defineMethod(date_proto, "setMonth", nativeDateSetMonth, 2);
    try vm.defineMethod(date_proto, "setUTCMonth", nativeDateSetMonth, 2);
    try vm.defineMethod(date_proto, "setDate", nativeDateSetDate, 1);
    try vm.defineMethod(date_proto, "setUTCDate", nativeDateSetDate, 1);
    try vm.defineMethod(date_proto, "setHours", nativeDateSetHours, 4);
    try vm.defineMethod(date_proto, "setUTCHours", nativeDateSetHours, 4);
    try vm.defineMethod(date_proto, "setMinutes", nativeDateSetMinutes, 3);
    try vm.defineMethod(date_proto, "setUTCMinutes", nativeDateSetMinutes, 3);
    try vm.defineMethod(date_proto, "setSeconds", nativeDateSetSeconds, 2);
    try vm.defineMethod(date_proto, "setUTCSeconds", nativeDateSetSeconds, 2);
    try vm.defineMethod(date_proto, "setMilliseconds", nativeDateSetMilliseconds, 1);
    try vm.defineMethod(date_proto, "setUTCMilliseconds", nativeDateSetMilliseconds, 1);
    const date_ctor = asCtor(try vm.makeNative("Date", nativeDate, 7));
    try vm.defineData(date_ctor, "prototype", Value.fromObject(date_proto), false, false, false);
    try vm.defineData(date_proto, "constructor", Value.fromObject(date_ctor), true, false, true);
    try vm.defineMethod(date_ctor, "now", nativeDateNow, 0);
    try vm.defineMethod(date_ctor, "UTC", nativeDateUTC, 7);
    try vm.defineMethod(date_ctor, "parse", nativeDateParse, 1);
    try vm.defineData(global, "Date", Value.fromObject(date_ctor), true, false, true);

    // ---- ArrayBuffer + TypedArrays ----
    const ab_proto = try vm.newObject(vm.object_proto);
    vm.arraybuffer_proto = ab_proto;
    const ab_ctor = asCtor(try vm.makeNative("ArrayBuffer", nativeArrayBuffer, 1));
    try vm.defineData(ab_ctor, "prototype", Value.fromObject(ab_proto), false, false, false);
    try vm.defineData(ab_proto, "constructor", Value.fromObject(ab_ctor), true, false, true);
    try vm.defineData(global, "ArrayBuffer", Value.fromObject(ab_ctor), true, false, true);

    const ta_proto = try vm.newObject(vm.object_proto);
    vm.typed_array_proto = ta_proto;
    try vm.defineMethod(ta_proto, "fill", nativeTAFill, 1);
    try vm.defineMethod(ta_proto, "set", nativeTASet, 1);
    try vm.defineMethod(ta_proto, "subarray", nativeTASubarray, 2);
    try vm.defineMethod(ta_proto, "join", nativeTAJoin, 1);
    try vm.defineMethod(ta_proto, "toString", nativeTAJoin, 0);
    try vm.defineMethod(ta_proto, "forEach", nativeTAForEach, 1);
    try vm.defineMethod(ta_proto, "indexOf", nativeTAIndexOf, 1);
    try vm.defineMethod(ta_proto, "values", nativeIterableValues, 0);
    try vm.defineData(ta_proto, vm.symbol_iterator_key, Value.fromObject(try vm.makeNative("values", nativeIterableValues, 0)), true, false, true);

    const ta_types = .{
        .{ "Int8Array", gc.TAKind.i8 },
        .{ "Uint8Array", gc.TAKind.u8 },
        .{ "Uint8ClampedArray", gc.TAKind.u8c },
        .{ "Int16Array", gc.TAKind.i16 },
        .{ "Uint16Array", gc.TAKind.u16 },
        .{ "Int32Array", gc.TAKind.i32 },
        .{ "Uint32Array", gc.TAKind.u32 },
        .{ "Float32Array", gc.TAKind.f32 },
        .{ "Float64Array", gc.TAKind.f64 },
    };
    inline for (ta_types) |t| {
        const proto = try vm.newObject(vm.typed_array_proto);
        const ctor = asCtor(try vm.makeNative(t[0], typedArrayConstructor(t[1]), 3));
        try vm.defineData(ctor, "prototype", Value.fromObject(proto), false, false, false);
        try vm.defineData(proto, "constructor", Value.fromObject(ctor), true, false, true);
        const bpe: f64 = @floatFromInt(gc.bytesPerElement(t[1]));
        try vm.defineData(ctor, "BYTES_PER_ELEMENT", Value.fromNumber(bpe), false, false, false);
        try vm.defineData(proto, "BYTES_PER_ELEMENT", Value.fromNumber(bpe), false, false, false);
        try vm.defineData(global, t[0], Value.fromObject(ctor), true, false, true);
    }

    // ---- DataView ----
    const dv_proto = try vm.newObject(vm.object_proto);
    vm.dataview_proto = dv_proto;
    try vm.defineMethod(dv_proto, "getInt8", dataViewGet(i8, false, true), 1);
    try vm.defineMethod(dv_proto, "getUint8", dataViewGet(u8, false, true), 1);
    try vm.defineMethod(dv_proto, "getInt16", dataViewGet(i16, false, false), 1);
    try vm.defineMethod(dv_proto, "getUint16", dataViewGet(u16, false, false), 1);
    try vm.defineMethod(dv_proto, "getInt32", dataViewGet(i32, false, false), 1);
    try vm.defineMethod(dv_proto, "getUint32", dataViewGet(u32, false, false), 1);
    try vm.defineMethod(dv_proto, "getFloat32", dataViewGet(f32, true, false), 1);
    try vm.defineMethod(dv_proto, "getFloat64", dataViewGet(f64, true, false), 1);
    try vm.defineMethod(dv_proto, "setInt8", dataViewSet(i8, false, true), 2);
    try vm.defineMethod(dv_proto, "setUint8", dataViewSet(u8, false, true), 2);
    try vm.defineMethod(dv_proto, "setInt16", dataViewSet(i16, false, false), 2);
    try vm.defineMethod(dv_proto, "setUint16", dataViewSet(u16, false, false), 2);
    try vm.defineMethod(dv_proto, "setInt32", dataViewSet(i32, false, false), 2);
    try vm.defineMethod(dv_proto, "setUint32", dataViewSet(u32, false, false), 2);
    try vm.defineMethod(dv_proto, "setFloat32", dataViewSet(f32, true, false), 2);
    try vm.defineMethod(dv_proto, "setFloat64", dataViewSet(f64, true, false), 2);
    const dv_ctor = asCtor(try vm.makeNative("DataView", nativeDataView, 1));
    try vm.defineData(dv_ctor, "prototype", Value.fromObject(dv_proto), false, false, false);
    try vm.defineData(dv_proto, "constructor", Value.fromObject(dv_ctor), true, false, true);
    try vm.defineData(global, "DataView", Value.fromObject(dv_ctor), true, false, true);

    // ---- Symbol ----
    const symbol_proto = try vm.newObject(vm.object_proto);
    vm.symbol_proto = symbol_proto;
    try vm.defineMethod(symbol_proto, "toString", nativeSymbolToString, 0);
    try vm.defineMethod(symbol_proto, "valueOf", nativeSymbolValueOf, 0);
    try vm.defineGetter(symbol_proto, "description", nativeSymbolDescription);
    const symbol_ctor = try vm.makeNative("Symbol", nativeSymbol, 0);
    try vm.defineData(symbol_ctor, "prototype", Value.fromObject(symbol_proto), false, false, false);
    try vm.defineData(symbol_proto, "constructor", Value.fromObject(symbol_ctor), true, false, true);
    try vm.defineMethod(symbol_ctor, "for", nativeSymbolFor, 1);
    try vm.defineMethod(symbol_ctor, "keyFor", nativeSymbolKeyFor, 1);
    const well_known = [_][]const u8{
        "iterator", "asyncIterator", "hasInstance", "isConcatSpreadable",
        "match",    "replace",       "search",      "split",
        "species",  "toPrimitive",   "toStringTag", "unscopables",
    };
    inline for (well_known) |name| {
        const sym = if (comptime std.mem.eql(u8, name, "iterator"))
            vm.symbol_iterator.?
        else
            try vm.makeSymbol("Symbol." ++ name);
        try vm.defineData(symbol_ctor, name, sym, false, false, false);
        // Capture the encoded keys of the symbols the engine consults.
        if (comptime std.mem.eql(u8, name, "toPrimitive")) {
            vm.symbol_to_primitive_key = try vm.toPropertyKey(sym);
        } else if (comptime std.mem.eql(u8, name, "toStringTag")) {
            vm.symbol_to_string_tag_key = try vm.toPropertyKey(sym);
        } else if (comptime std.mem.eql(u8, name, "hasInstance")) {
            vm.symbol_has_instance_key = try vm.toPropertyKey(sym);
        } else if (comptime std.mem.eql(u8, name, "match")) {
            vm.symbol_match_key = try vm.toPropertyKey(sym);
        } else if (comptime std.mem.eql(u8, name, "replace")) {
            vm.symbol_replace_key = try vm.toPropertyKey(sym);
        } else if (comptime std.mem.eql(u8, name, "search")) {
            vm.symbol_search_key = try vm.toPropertyKey(sym);
        } else if (comptime std.mem.eql(u8, name, "split")) {
            vm.symbol_split_key = try vm.toPropertyKey(sym);
        }
    }

    // RegExp.prototype implements the string-pattern protocol; String methods
    // dispatch through these, so custom pattern objects can hook them too.
    try vm.defineMethod(vm.regexp_proto.?, vm.symbol_match_key, nativeRegExpSymbolMatch, 1);
    try vm.defineMethod(vm.regexp_proto.?, vm.symbol_replace_key, nativeRegExpSymbolReplace, 2);
    try vm.defineMethod(vm.regexp_proto.?, vm.symbol_search_key, nativeRegExpSymbolSearch, 1);
    try vm.defineMethod(vm.regexp_proto.?, vm.symbol_split_key, nativeRegExpSymbolSplit, 2);
    try vm.defineData(global, "Symbol", Value.fromObject(symbol_ctor), true, false, true);

    // ---- BigInt ----
    const bigint_proto = try vm.newObject(vm.object_proto);
    vm.bigint_proto = bigint_proto;
    const bigint_ctor = try vm.makeNative("BigInt", nativeBigInt, 1);
    try vm.defineData(bigint_ctor, "prototype", Value.fromObject(bigint_proto), false, false, false);
    try vm.defineData(bigint_proto, "constructor", Value.fromObject(bigint_ctor), true, false, true);
    try vm.defineMethod(bigint_proto, "toString", nativeBigIntToString, 0);
    try vm.defineMethod(bigint_proto, "toLocaleString", nativeBigIntToString, 0);
    try vm.defineMethod(bigint_proto, "valueOf", nativeBigIntValueOf, 0);
    try vm.defineMethod(bigint_ctor, "asIntN", nativeBigIntAsIntN, 2);
    try vm.defineMethod(bigint_ctor, "asUintN", nativeBigIntAsUintN, 2);
    if (vm.symbol_to_string_tag_key.len != 0) {
        try vm.defineData(bigint_proto, vm.symbol_to_string_tag_key, try vm.makeString("BigInt"), false, false, true);
    }
    try vm.defineData(global, "BigInt", Value.fromObject(bigint_ctor), true, false, true);

    // ---- Proxy + Reflect ----
    const proxy_ctor = asCtor(try vm.makeNative("Proxy", nativeProxy, 2));
    try vm.defineMethod(proxy_ctor, "revocable", nativeProxyRevocable, 2);
    try vm.defineData(global, "Proxy", Value.fromObject(proxy_ctor), true, false, true);

    const reflect = try vm.newObject(vm.object_proto);
    try vm.defineMethod(reflect, "get", nativeReflectGet, 2);
    try vm.defineMethod(reflect, "set", nativeReflectSet, 3);
    try vm.defineMethod(reflect, "has", nativeReflectHas, 2);
    try vm.defineMethod(reflect, "deleteProperty", nativeReflectDelete, 2);
    try vm.defineMethod(reflect, "ownKeys", nativeReflectOwnKeys, 1);
    try vm.defineMethod(reflect, "getPrototypeOf", nativeReflectGetProto, 1);
    try vm.defineMethod(reflect, "apply", nativeReflectApply, 3);
    try vm.defineMethod(reflect, "construct", nativeReflectConstruct, 2);
    try vm.defineData(global, "Reflect", Value.fromObject(reflect), true, false, true);

    // ---- JSON ----
    const json = try vm.newObject(vm.object_proto);
    try vm.defineMethod(json, "stringify", nativeJSONStringify, 3);
    try vm.defineMethod(json, "parse", nativeJSONParse, 2);
    try vm.defineData(global, "JSON", Value.fromObject(json), true, false, true);

    // ---- console + print ----
    const console = try vm.newObject(vm.object_proto);
    try vm.defineMethod(console, "log", nativeConsoleLog, 0);
    try vm.defineMethod(console, "info", nativeConsoleLog, 0);
    try vm.defineMethod(console, "debug", nativeConsoleLog, 0);
    try vm.defineMethod(console, "error", nativeConsoleError, 0);
    try vm.defineMethod(console, "warn", nativeConsoleError, 0);
    try vm.defineData(global, "console", Value.fromObject(console), true, false, true);
    try vm.defineMethod(global, "print", nativeConsoleLog, 1);

    // ---- global functions ----
    try vm.defineMethod(global, "isNaN", nativeIsNaN, 1);
    try vm.defineMethod(global, "isFinite", nativeIsFinite, 1);
    try vm.defineMethod(global, "eval", nativeEval, 1);
    try vm.defineMethod(global, "parseInt", nativeParseInt, 2);
    try vm.defineMethod(global, "parseFloat", nativeParseFloat, 1);
    try vm.defineMethod(global, "encodeURI", nativeEncodeURI, 1);
    try vm.defineMethod(global, "encodeURIComponent", nativeEncodeURIComponent, 1);
    try vm.defineMethod(global, "decodeURI", nativeDecodeURIComponent, 1);
    try vm.defineMethod(global, "decodeURIComponent", nativeDecodeURIComponent, 1);
    try vm.defineMethod(number_ctor, "parseInt", nativeParseInt, 2);
    try vm.defineMethod(number_ctor, "parseFloat", nativeParseFloat, 1);
}
