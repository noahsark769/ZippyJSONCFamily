//Copyright (c) 2018 Michael Eisel. All rights reserved.

// NOTE: ARC is disabled for this file

#import "JSONSerialization_Private.h"
#import "JSONSerialization.h"
#import <CoreFoundation/CoreFoundation.h>
#import "simdjson.h"
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <math.h>
#import "libbase64.h"
#import <string.h>
#import <atomic>
#import <mutex>

using namespace simdjson;

typedef struct {
    char *string;
    size_t capacity;
} JNTString;

static inline char JNTStringPop(char **string) {
    char c = **string;
    (*string)++;
    return c;
}

static inline void JNTStringPush(char **string, char c) {
    **string = c;
    (*string)++;
}

static __thread JNTDecodingError tError = {0};
static __thread JNTString tSnakeCaseBuffer = {0};

static __thread char *tPosInfString;
static __thread char *tNegInfString;
static __thread char *tNanString;


// todo: static everywhere that it should be

static const char *JNTStringForType(uint8 type) {
    switch (type) {
        case 'n':
            return "null";
        case 't':
        case 'f':
            return "Bool";
        case '{':
            return "Dictionary";
        case '[':
            return "Array";
        case '"':
            return "String";
        case 'd':
        case 'l':
            return "Number";
    }
    return "?";
}

static void JNTHandleJSONParsingFailed(int res) {
    char *description = nullptr;
    asprintf(&description, "The given data was not valid JSON. Error: %s", simdjson::errorMsg(res).c_str());
    tError = {
        .description = description,
        .type = JNTDecodingErrorTypeJSONParsingFailed,
    };
}

static void JNTHandleWrongType(ParsedJson::iterator *iterator, uint8 type, const char *expectedType) {
    JNTDecodingErrorType errorType = type == 'n' ? JNTDecodingErrorTypeValueDoesNotExist : JNTDecodingErrorTypeWrongType;
    char *description = nullptr;
    asprintf(&description, "Expected %s value but found %s instead.", JNTStringForType(type), expectedType);
    ParsedJson::iterator *value = new ParsedJson::iterator(*iterator);
    tError = {
        .description = description,
        .type = errorType,
        .value = value,
    };
}

static void JNTHandleMemberDoesNotExist(ParsedJson::iterator *iterator, const char *key) {
    NSString *message = [NSString stringWithFormat:@"No value associated with %s.", key];
    char *description = nullptr;
    asprintf(&description, "No value associated with %s.", key);
    tError = {
        .description = description,
        .type = JNTDecodingErrorTypeKeyDoesNotExist,
        .value = new ParsedJson::iterator(*iterator),
        .key = key,
    };
}

template <typename T>
static void JNTHandleNumberDoesNotFit(ParsedJson::iterator *iterator, T number, const char *type) {
    char *description = nullptr;
    NS_VALID_UNTIL_END_OF_SCOPE NSString *string = [@(number) description];
    asprintf(&description, "Parsed JSON number %s does not fit in %s.", string.UTF8String, type);
    tError = {
        .description = description,
        .type = JNTDecodingErrorTypeNumberDoesNotFit,
        .value = new ParsedJson::iterator(*iterator),
    };
}

static const size_t kSnakeCaseBufferInitialSize = 100;

static void JNTStringGrow(JNTString *string, size_t newSize) {
    string->capacity = newSize;
    string->string = (char *)realloc((void *)string->string, newSize);
}

static inline bool JNTIsLower(char c) {
    return 'a' <= c && c <= 'z';
}

static inline bool JNTIsUpper(char c) {
    return 'A' <= c && c <= 'Z';
}

static inline char JNTToUpper(char c) {
    return JNTIsLower(c) ? c + ('A' - 'a') : c;
}

static inline char JNTToLower(char c) {
    return JNTIsUpper(c) ? c + ('a' - 'A') : c;
}

static void JNTUpdateBufferForSnakeCase(const char *key) {
    if (!tSnakeCaseBuffer.string) {
        JNTStringGrow(&tSnakeCaseBuffer, kSnakeCaseBufferInitialSize);
    }
    size_t maxLength = strlen(key) * 2 + 2;
    if (maxLength > tSnakeCaseBuffer.capacity) {
        JNTStringGrow(&tSnakeCaseBuffer, maxLength);
    }
    char *snakeCurrent = tSnakeCaseBuffer.string;
    char *debug = tSnakeCaseBuffer.string;
    if (key[0] == '\0') {
        *snakeCurrent = '\0';
        return;
    }

    *snakeCurrent = JNTToLower(key[0]);
    snakeCurrent++;
    const char *currentPointer = &(key[1]);
    const char *previousPointer = currentPointer;
    char current = *currentPointer;
    while (current != '\0') {
        while (!JNTIsUpper(current) && current != '\0') {
            *snakeCurrent = current;
            snakeCurrent++;
            currentPointer++;
            current = *currentPointer;
        }
        if (current != '\0') {
            *snakeCurrent = '_';
            snakeCurrent++;
        }
        previousPointer = currentPointer;
        while (!JNTIsLower(current) && current != '\0') {
            *snakeCurrent = JNTToLower(current);
            snakeCurrent++;

            currentPointer++;
            current = *currentPointer;
        }
        size_t distance = (size_t)(currentPointer - previousPointer);
        if (distance >= 2 && current != '\0') {
            char temp = snakeCurrent[-1];
            snakeCurrent[-1] = '_';
            *snakeCurrent = temp;
            snakeCurrent++;
        }
        previousPointer = currentPointer;
    }
    *snakeCurrent = '\0';
}

JNTDecodingError *JNTError() {
    return &tError;
}


static std::mutex sEmptyDictionaryMutex;
static ParsedJson *sEmptyDictionaryJson;
static ParsedJson::iterator *sEmptyDictionaryIterator;
// Unless the lib ever supports custom key decoding, it will never try to lookup an empty string as a key
static const char kEmptyDictionaryString[] = "{'': 0}";
static const char kEmptyDictionaryStringLength = sizeof(kEmptyDictionaryString) - 1;

const void *JNTEmptyDictionaryIterator() {
    if (!sEmptyDictionaryJson) {
        sEmptyDictionaryMutex.lock();
        if (!sEmptyDictionaryJson) {
            sEmptyDictionaryJson = new ParsedJson;
            sEmptyDictionaryJson->allocateCapacity(kEmptyDictionaryStringLength);
            json_parse(kEmptyDictionaryString, kEmptyDictionaryStringLength, *sEmptyDictionaryJson);
            sEmptyDictionaryIterator = new ParsedJson::iterator(*sEmptyDictionaryJson);
        }
        sEmptyDictionaryMutex.unlock();
    }
    return sEmptyDictionaryIterator;
}

inline uint32_t JNTReplaceSnakeWithCamel(char *string) {
    char *end = string + strlen(string);
    char *currString = string;
    JNTStringGrow(&tSnakeCaseBuffer, end - string + 1);
    char *output = tSnakeCaseBuffer.string;
    char *currOutput = output;
    while (currString < end) {
        if (*currString != '_') {
            break;
        }
        JNTStringPush(&currOutput, '_');
        currString++;
    }
    if (currString == end) {
        return end - string;
    }
    char *originalEnd = end;
    end--;
    while (*end == '_') {
        end--;
    }
    end++;
    bool didHitUnderscore = false;
    size_t leadingUnderscoreCount = currString - string;
    while (currString < end) {
        char first = JNTStringPop(&currString);
        JNTStringPush(&currOutput, JNTToUpper(first));
        while (currString < end && *currString != '_') {
            char c = JNTStringPop(&currString);
            JNTStringPush(&currOutput, JNTToLower(c));
        }
        while (currString < end && *currString == '_') {
            didHitUnderscore = true;
            currString++;
        }
    }
    if (!didHitUnderscore) {
        return originalEnd - string;
    }
    output[leadingUnderscoreCount] = JNTToLower(output[leadingUnderscoreCount]); // If the first got capitalized
    for (NSInteger i = 0; i < originalEnd - end; i++) {
        JNTStringPush(&currOutput, '_');
    }
    JNTStringPush(&currOutput, '\0');
    memcpy(string, output, currOutput - output);
    return currOutput - output - 1;
}

void JNTConvertSnakeToCamel(const void *iteratorAsVoid) {
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)iteratorAsVoid;
    do {
        if (!iterator->is_string()) {
            return;
        }
        uint32_t newLength = JNTReplaceSnakeWithCamel((char *)iterator->get_string());
        iterator->set_string_length(newLength);
        iterator->move_to_value();
    } while (iterator->next());
}

static inline bool JNTChecker(const char *s) {
    char has = '\0';
    while (*s != '\0') {
        has |= *s;
        s++;
    }
    return (has & 0x80) != 0;
}

// Check if there are any non-ASCII chars in the dictionary keys
static bool JNTCheck(ParsedJson::iterator i) {
    bool has = false;
    if (i.is_object()) {
        if (!i.down()) {
            return false;
        }
        do {
            has |= JNTChecker(i.get_string());
            i.move_to_value();
            if (i.is_object_or_array()) {
                has |= JNTCheck(i);
            }
        } while (i.next());
    } else if (i.is_array()) {
        if (!i.down()) {
            return false;
        }
        do {
            if (i.is_string()) {
                has |= JNTChecker(i.get_string());
            } else if (i.is_object_or_array()) {
                has |= JNTCheck(i);
            }
        } while (i.next());
    }
    return has;
}

// todo: what if simdjson is given "{2: "a"}"?

__thread ParsedJson *doc = NULL;
__thread std::deque<ParsedJson::iterator> *tIterators;

const void *JNTDocumentFromJSON(const void *data, NSInteger length, bool convertCase, const char * *retryReason) {
    char *bytes = (char *)data;
    doc = new ParsedJson;
    doc->allocateCapacity(length); // todo: why warning?
    tIterators = new std::deque<ParsedJson::iterator>();
    const int res = json_parse((const char *)data, length, *doc); // todo: handle error code
    if (res != 0) {
        if (res != NUMBER_ERROR) { // retry number errors
            JNTHandleJSONParsingFailed(res);
        } else {
            *retryReason = "A number was too large (couldn't fit in a 64-bit integer, be it signed or unsigned)";
        }
        return NULL;
    }
    ParsedJson::iterator iterator = ParsedJson::iterator(*doc); // todo: is this deallocated?
    if (JNTCheck(iterator)) {
        *retryReason = "One or more keys had non-ASCII characters";
        return NULL;
    } else {
        tIterators->push_back(iterator);
        return &(tIterators->back());
    }
}

void JNTReleaseDocument(const void *document) {
    if (tError.description != NULL) {
        free((void *)tError.description);
    }
    if (tError.value != NULL) {
        delete ((ParsedJson::iterator *)tError.value);
    }
    tError = {0};
    if (tPosInfString) {
        free(tPosInfString);
        free(tNegInfString);
        free(tNanString);
        tPosInfString = tNegInfString = tNanString = NULL;
    }
    delete (ParsedJson *)doc;
    delete tIterators;
}

BOOL JNTDocumentContains(const void *valueAsVoid, const char *key) {
    bool found = false;
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)valueAsVoid;
    iterator->prev_string();
    return iterator->search_for_key(key, strlen(key));
}

namespace TypeChecker {
    bool Object(ParsedJson::iterator *value) {
        return value->is_object();
    }
    struct Double {
        bool operator() (ParsedJson::iterator *value) {
            return value->is_double();
        }
    };
    //struct Uint64 {
    bool Uint64(ParsedJson::iterator *value) {
        return value->is_integer();
    }
    //};
    //struct Int64 {
    bool Int64(ParsedJson::iterator *value) {
        return value->is_integer();
    }
    //};
    bool String(ParsedJson::iterator *value) {
        return value->is_string();
    }

    bool Size(ParsedJson::iterator *value) {
        return value->is_integer();
    }

    bool USize(ParsedJson::iterator *value) {
        return value->is_integer();
    }

    bool Bool(ParsedJson::iterator *value) {
        return value->is_true() || value->is_false();
    }

    bool Array(ParsedJson::iterator *value) {
        return value->is_array();
    }
}

namespace Converter {
    struct Double {
        double operator() (ParsedJson::iterator *value) {
            return value->get_double();
        }
    };
    //struct Uint64 {
    uint64_t Uint64(ParsedJson::iterator *value) {
        return value->get_integer();
    }
    //};
    //struct Int64 {
    int64_t Int64(ParsedJson::iterator *value) {
        return value->get_integer();
    }
    //};
    NSInteger Size(ParsedJson::iterator *value) {
        return (NSInteger)value->get_integer();
    }

    NSUInteger USize(ParsedJson::iterator *value) {
        return (NSUInteger)value->get_integer();
    }

    const char *String(ParsedJson::iterator *value) {
        return value->get_string();
    }

    bool Bool(ParsedJson::iterator *value) {
        return value->is_true();
    }

    void Object(ParsedJson::iterator *value) {
        assert(false);
        value->down();
    }

    void Array(ParsedJson::iterator *value) {
        assert(false);
        value->down();
    }
}

template <typename T, typename U, bool (*TypeCheck)(ParsedJson::iterator *), U (*Convert)(ParsedJson::iterator *)>
T JNTDocumentDecode(ParsedJson::iterator *value) {
    if (unlikely(!TypeCheck(value))) {
        JNTHandleWrongType(value, value->get_type(), typeid(T).name());
        return 0;
    }
    U number = Convert(value);
    T result = (T)number;
    if (unlikely(number != result)) {
        JNTHandleNumberDoesNotFit(value, number, typeid(T).name());
        return 0;
    }
    return result;
}

void JNTDocumentNextArrayElement(const void *iteratorAsVoid, bool *isAtEnd) {
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)iteratorAsVoid;
    *isAtEnd = !iterator->next();
}

BOOL JNTDocumentDecodeNil(const void *valueAsVoid) {
    ParsedJson::iterator *value = (ParsedJson::iterator *)valueAsVoid;
    return value->is_null();
}

bool JNTIsString(const void *valueAsVoid) {
    ParsedJson::iterator *value = (ParsedJson::iterator *)valueAsVoid;
    return value->is_string();
}

__thread bool tThreadLocked = false;

bool JNTAcquireThreadLock() {
    bool threadWasLocked = tThreadLocked;
    tThreadLocked = true;
    return !threadWasLocked;
}

void JNTReleaseThreadLock() {
    tThreadLocked = false;
}

void JNTUpdateFloatingPointStrings(const char *posInfString, const char *negInfString, const char *nanString) {
    asprintf(&tPosInfString, "%s", posInfString);
    asprintf(&tNegInfString, "%s", negInfString);
    asprintf(&tNanString, "%s", nanString);
}

double JNTDocumentDecode__Double(const void *valueAsVoid) {
    ParsedJson::iterator *value = (ParsedJson::iterator *)valueAsVoid;
    if (value->is_double()) {
        return value->get_double();
    } else if (value->is_integer()){
        return (double)value->get_integer();
    } else {
        if (value->is_string()) {
            const char *string = value->get_string();
            if (strcmp(string, tPosInfString) == 0) {
                return INFINITY;
            } else if (strcmp(string, tNegInfString) == 0) {
                return -INFINITY;
            } else if (strcmp(string, tNanString) == 0) {
                return NAN;
            }
        }
        JNTHandleWrongType(value, value->get_type(), "double/float");
        return 0;
    }
}

float JNTDocumentDecode__Float(const void *valueAsVoid) {
    ParsedJson::iterator *value = (ParsedJson::iterator *)valueAsVoid;
    double d = JNTDocumentDecode__Double(value);
    return (float)d;
}

NSDecimalNumber *JNTDocumentDecode__Decimal(const void *valueAsVoid) {
    // Value *value = (Value *)valueAsVoid;
    abort();
    return [[NSDecimalNumber alloc] initWithInt:0];
}

static int JNTDataFromBase64String(size_t inLength, int32_t *outLength, const char *str, char **outBuffer) {
    // *outBuffer = (char *)malloc(inLength * 3 / 4 + 4);
    // size_t outlen = 0;
    // int errorStatus = base64_decode(str, inLength, *outBuffer, &outlen, 0);
    // *outLength = (int32_t)outlen;
    // return errorStatus;
    return 0;
}

void *JNTDocumentDecode__Data(const void *valueAsVoid, int32_t *outLength) {
    abort();
    /*Value *value = (Value *)valueAsVoid;
    const char *str = JNTDocumentDecode__String(valueAsVoid);
    size_t inLength = value->GetStringLength();
    char *outBuffer = NULL;
    int errorStatus = JNTDataFromBase64String(inLength, outLength, str, &outBuffer);
    // todo: catch errors here
    // todo: compared to the default options of apples based sixty four decoder
    return outBuffer;*/
}

NSDate *JNTDocumentDecode__Date(const void *valueAsVoid) {
    // Value *value = (Value *)valueAsVoid;
    abort();
    return [NSDate date];
}

// Test helper
const char *JNTSnakeCaseFromCamel(const char *key) {
    JNTUpdateBufferForSnakeCase(key);
    return tSnakeCaseBuffer.string;
}

// std::vector<ParsedJson::iterator> iterators();
// static const int kIteratorAccount
// ParsedJson::iterator iterators[kIteratorCount];

bool JNTIteratorsEqual(ParsedJson::iterator *i1, ParsedJson::iterator *i2) {
    return i1->get_tape_location() == i2->get_tape_location();
}

NSMutableArray <id> *JNTDocumentCodingPathHelper(ParsedJson::iterator iterator, ParsedJson::iterator *targetIterator) {
    if (iterator.is_array()) {
        if (iterator.down()) {
            NSInteger i = 0;
            do {
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(i)] mutableCopy];
                } else if (iterator.is_object_or_array()) {
                    NSMutableArray *codingPath = JNTDocumentCodingPathHelper(iterator, targetIterator);
                    if (codingPath) {
                        [codingPath insertObject:@(i) atIndex:0];
                        return codingPath;
                    }
                }
            } while (iterator.next());
        }
    } else if (iterator.is_object()) {
        if (iterator.down()) {
            do {
                const char *key = iterator.get_string();
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(key)] mutableCopy];
                }
                iterator.move_to_value();
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(key)] mutableCopy];
                } else if (iterator.is_object_or_array()) {
                    NSMutableArray *codingPath = JNTDocumentCodingPathHelper(iterator, targetIterator);
                    if (codingPath) {
                        [codingPath insertObject:@(key) atIndex:0];
                        return codingPath;
                    }
                }
            } while (iterator.next());
        }
    }
}

NSArray <id> *JNTDocumentCodingPath(const void *iteratorAsVoid) {
    ParsedJson::iterator *targetIterator = (ParsedJson::iterator *)iteratorAsVoid;
    ParsedJson::iterator iterator = ParsedJson::iterator(*doc); // todo: copy constructor? deallocation of iterator?
    if (JNTIteratorsEqual(&iterator, targetIterator)) {
        return @[];
    }
    return JNTDocumentCodingPathHelper(iterator, targetIterator) ?: @[];
}

NSArray <NSString *> *JNTDocumentAllKeys(const void *valueAsVoid) {
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)valueAsVoid;
    if (iterator->is_object()) {
        return @[];
    }
    NSMutableArray <NSString *>*keys = [NSMutableArray array];
    iterator->to_start_scope();
    do {
        if (!iterator->is_string()) {
            break;
        }
        [keys addObject:@(iterator->get_string())];
        iterator->move_to_value();
    } while (iterator->next());
    return [keys copy];
}

void JNTDocumentForAllKeyValuePairs(const void *iteratorAsVoid, void (^callback)(const char *key, const void *iteratorAsVoid)) {
    // Make a copy of the iterator
    ParsedJson::iterator iterator = *((ParsedJson::iterator *)iteratorAsVoid);
    // todo: add assertions everywhere apple does, in case the user is doing something weird
    if (iterator.get_scope_type() != '{') {
        // todo: a
        return;
    }
    if (!iterator.down()) {
        return;
    }
    do {
        const char *key = iterator.get_string();
        iterator.move_to_value();
        callback(key, &iterator);
    } while (iterator.next());
}

const void *JNTDocumentEnterStructureAndReturnCopy(const void *iteratorAsVoid) {
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)iteratorAsVoid;
    tIterators->emplace_back(*iterator);
    if (tIterators->back().down()) {
        return &(tIterators->back());
    } else {
        if (tIterators->back().is_array()) {
            tIterators->pop_back();
            return NULL;
        } else {
            return sEmptyDictionaryJson;
        }
    }
}

__attribute__((always_inline)) const void *JNTDocumentFetchValue(const void *valueAsVoid, const char *key) {
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)valueAsVoid;
    iterator->prev_string();
    iterator->search_for_key(key, strlen(key));
    // todo: handle key not found
    /*if (iterator->is_object_or_array()) {
        return JNTDocumentEnterStructureAndReturnCopy(iterator);
    }*/
    return iterator;
}
// todo: case where iterator starts searching at end of scope, ie '}'

bool JNTDocumentValueIsDictionary(const void *iteratorAsVoid) {
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)iteratorAsVoid;
    return iterator->is_object();
}

bool JNTDocumentValueIsArray(const void *iteratorAsVoid) {
    ParsedJson::iterator *iterator = (ParsedJson::iterator *)iteratorAsVoid;
    return iterator->is_array();
}

#define DECODE(A, B, C, D) DECODE_NAMED(A, B, C, D, A)

#define DECODE_NAMED(A, B, C, D, E) \
A JNTDocumentDecode__##E(const void *value) { \
    return JNTDocumentDecode<A, B, TypeChecker::C, Converter::D>((ParsedJson::iterator *)value); \
}
ENUMERATE(DECODE);

void JNTRunTests() {
    NSString *string = @"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    for (NSUInteger i = 0; i < string.length; i++) {
        NSString *substring = [string substringToIndex:i];
        NSData *data = [[[NSData alloc] initWithBytes:substring.UTF8String length:i] base64EncodedDataWithOptions:0];
        int32_t outLength = 0;
        char *outBuffer = NULL;
        JNTDataFromBase64String((size_t)data.length, &outLength, (const char *)data.bytes, &outBuffer);
        assert(outLength == i && memcmp(string.UTF8String, outBuffer, outLength) == 0);
    }
}



// todo: NSNull, UInt64, Int64
// todo: concurrent usage
// todo: json test suites
// todo: non- objectJSON
// todo: throwing behavior
// todo: disable testability for release?
// todo: exceptions without memory leaks
// todo: external representation for string initializer's?
// public private visibility
// retains on objects in collections?
// todo: retains on UInt64s?
// todo: what if the string is released a couple times but still retained in other places
// todo: -Ofast?
// todo: kParseValidateEncodingFlag, kParseNanAndInfFlag
// todo: bridging cost of nsstring
// todo: nonconforming floats
// todo: class or struct types for the decoders?
// todo: asan
// todo: unknown reference to decoder
// todo: json keys with utf-8 characters
//todo: _JSONStringDictionaryDecodableMarker.Type investigation
// todo: cases where it fails but continues like when it tries to decode data from a string probably needs to be fixed
// todo: make sure that base64 works and does not overflow the buffer
// todo: cindy json does not support 32-bit
// todo: make sure architecture optimizations are turned on or else it won't run correctly
// todo: swift seems to be fetching keys excessively
// todo: handle empty arrays
// todo: use a pool of containers to avoid allocations?
// todo: test when a float is attempted to be unwrapped as an int and vice versa
// todo: simdjson stable version and not debug?
// todo: swift 5.0?
