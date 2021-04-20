/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/API/FSTUserDataReader.h"

#import <FirebaseFirestore/FIRFieldValue.h>
#import <FirebaseFirestore/FIRGeoPoint.h>
#import <FirebaseFirestore/FIRTimestamp.h>
#import <XCTest/XCTest.h>

#import "Firestore/Example/Tests/Util/FSTHelpers.h"
#import "Firestore/Source/API/converters.h"

#include "Firestore/core/src/model/database_id.h"
#include "Firestore/core/src/model/field_value.h"
#include "Firestore/core/src/model/patch_mutation.h"
#include "Firestore/core/src/model/set_mutation.h"
#include "Firestore/core/src/model/transform_operation.h"
#include "Firestore/core/src/nanopb/nanopb_util.h"
#include "Firestore/core/test/unit/testutil/testutil.h"

namespace util = firebase::firestore::util;
using firebase::firestore::api::MakeGeoPoint;
using firebase::firestore::api::MakeTimestamp;
using firebase::firestore::model::ArrayTransform;
using firebase::firestore::model::DatabaseId;
using firebase::firestore::model::FieldPath;
using firebase::firestore::google_firestore_v1_Value;
using firebase::firestore::model::FieldTransform;
using firebase::firestore::model::ObjectValue;
using firebase::firestore::model::PatchMutation;
using firebase::firestore::model::TransformOperation;
using firebase::firestore::model::SetMutation;
using firebase::firestore::nanopb::MakeNSData;
using firebase::firestore::testutil::Field;

@interface FSTUserDataReaderTests : XCTestCase
@end

@implementation FSTUserDataReaderTests

- (void)testConvertsIntegers {
  NSArray<NSNumber *> *values = @[
    @(INT_MIN), @(-1), @0, @1, @2, @(UCHAR_MAX), @(INT_MAX),  // Standard integers
    @(LONG_MIN), @(LONG_MAX), @(LLONG_MIN), @(LLONG_MAX)      // Larger values
  ];
  for (NSNumber *value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kInteger);
    XCTAssertEqual(wrapped.integer_value(), [value longLongValue]);
  }
}

- (void)testConvertsDoubles {
  // Note that 0x1.0p-1074 is a hex floating point literal representing the minimum subnormal
  // number: <https://en.wikipedia.org/wiki/Denormal_number>.
  NSArray<NSNumber *> *values = @[
    @(-INFINITY), @(-DBL_MAX), @(LLONG_MIN * -1.0), @(-1.1), @(-0x1.0p-1074), @(-0.0), @(0.0),
    @(0x1.0p-1074), @(DBL_MIN), @(1.1), @(LLONG_MAX * 1.0), @(DBL_MAX), @(INFINITY)
  ];
  for (NSNumber *value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kDouble);
    XCTAssertEqual(wrapped.double_value(), [value doubleValue]);
  }
}

- (void)testConvertsNilAndNSNull {
  FieldValue nullValue = FieldValue::Null();
  XCTAssertEqual(nullValue.type(), TypeOrder::kNull);
  XCTAssertEqual(FSTTestFieldValue(nil), nullValue);
  XCTAssertEqual(FSTTestFieldValue([NSNull null]), nullValue);
}

- (void)testConvertsBooleans {
  NSArray<NSNumber *> *values = @[ @YES, @NO ];
  for (NSNumber *value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kBoolean);
    XCTAssertEqual(wrapped.boolean_value(), [value boolValue]);
  }
}

- (void)testConvertsUnsignedCharToInteger {
  // See comments in FSTUserDataReader regarding handling of signed char. Essentially, signed
  // char has to be treated as boolean. Unsigned chars could conceivably be handled consistently
  // with signed chars but on arm64 these end up being stored as signed shorts. This forces us to
  // choose, and it's more useful to support shorts as Integers than it is to treat unsigned char as
  // Boolean.
  FieldValue wrapped = FSTTestFieldValue([NSNumber numberWithUnsignedChar:1]);
  XCTAssertEqual(wrapped, FieldValue::FromInteger(1));
}

union DoubleBits {
  double d;
  uint64_t bits;
};

- (void)testConvertsStrings {
  NSArray<NSString *> *values = @[ @"", @"abc" ];
  for (id value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kString);
    XCTAssertEqual(wrapped.string_value(), util::MakeString(value));
  }
}

- (void)testConvertsDates {
  NSArray<NSDate *> *values =
      @[ FSTTestDate(1900, 12, 1, 1, 20, 30), FSTTestDate(2017, 4, 24, 13, 20, 30) ];
  for (NSDate *value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kTimestamp);
    XCTAssertEqual(wrapped.timestamp_value(), MakeTimestamp(value));
  }
}

- (void)testConvertsGeoPoints {
  NSArray<FIRGeoPoint *> *values = @[ FSTTestGeoPoint(1.24, 4.56), FSTTestGeoPoint(-20, 100) ];

  for (FIRGeoPoint *value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kGeoPoint);
    XCTAssertEqual(wrapped.geo_point_value(), MakeGeoPoint(value));
  }
}

- (void)testConvertsBlobs {
  NSArray<NSData *> *values = @[ FSTTestData(1, 2, 3, -1), FSTTestData(1, 2, -1) ];
  for (NSData *value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kBlob);
    XCTAssertEqualObjects(MakeNSData(wrapped.blob_value()), value);
  }
}

- (void)testConvertsResourceNames {
  NSArray<FSTDocumentKeyReference *> *values = @[
    FSTTestRef("project", DatabaseId::kDefault, @"foo/bar"),
    FSTTestRef("project", DatabaseId::kDefault, @"foo/baz")
  ];
  for (FSTDocumentKeyReference *value in values) {
    FieldValue wrapped = FSTTestFieldValue(value);
    XCTAssertEqual(wrapped.type(), TypeOrder::kReference);
    XCTAssertEqual(wrapped.reference_value().key(), value.key);
    XCTAssertTrue(wrapped.reference_value().database_id() == value.databaseID);
  }
}

- (void)testConvertsEmptyObjects {
  XCTAssertEqual(ObjectValue(FSTTestFieldValue(@{})), ObjectValue::Empty());
  XCTAssertEqual(FSTTestFieldValue(@{}).type(), TypeOrder::kObject);
}

- (void)testConvertsSimpleObjects {
  ObjectValue actual =
      FSTTestObjectValue(@{@"a" : @"foo", @"b" : @(1L), @"c" : @YES, @"d" : [NSNull null]});
  ObjectValue expected = ObjectValue::FromMapValue({{"a", FieldValue::FromString("foo")},
                                                    {"b", FieldValue::FromInteger(1)},
                                                    {"c", FieldValue::True()},
                                                    {"d", FieldValue::Null()}});
  XCTAssertEqual(actual, expected);
  XCTAssertEqual(actual.AsFieldValue().type(), TypeOrder::kObject);
}

- (void)testConvertsNestedObjects {
  ObjectValue actual = FSTTestObjectValue(@{@"a" : @{@"b" : @{@"c" : @"foo"}, @"d" : @YES}});
  ObjectValue expected = ObjectValue::FromMapValue({
      {"a", ObjectValue::FromMapValue(
                {{"b", ObjectValue::FromMapValue({{"c", FieldValue::FromString("foo")}})},
                 {"d", FieldValue::True()}})},
  });
  XCTAssertEqual(actual, expected);
  XCTAssertEqual(actual.AsFieldValue().type(), TypeOrder::kObject);
}

- (void)testConvertsArrays {
  FieldValue expected = FieldValue::FromArray({
      FieldValue::FromString("value"),
      FieldValue::True(),
  });

  FieldValue actual = (FieldValue)FSTTestFieldValue(@[ @"value", @YES ]);
  XCTAssertEqual(actual, expected);
  XCTAssertEqual(actual.type(), TypeOrder::kArray);
}

- (void)testNSDatesAreConvertedToTimestamps {
  NSDate *date = [NSDate date];
  id input = @{@"array" : @[ @1, date ], @"obj" : @{@"date" : date, @"string" : @"hi"}};
  ObjectValue value = FSTTestObjectValue(input);
  {
    auto array = value.Get(Field("array"));
    XCTAssertTrue(array.has_value());
    XCTAssertEqual(array->type(), TypeOrder::kArray);

    const FieldValue &actual = array->array_value()[1];
    XCTAssertEqual(actual.type(), TypeOrder::kTimestamp);
    XCTAssertEqual(actual.timestamp_value(), MakeTimestamp(date));
  }
  {
    auto found = value.Get(Field("obj.date"));
    XCTAssertTrue(found.has_value());
    XCTAssertEqual(found->type(), TypeOrder::kTimestamp);
    XCTAssertEqual(found->timestamp_value(), MakeTimestamp(date));
  }
}

- (void)testCreatesArrayUnionTransforms {
  PatchMutation patchMutation = FSTTestPatchMutation(@"collection/key", @{
    @"foo" : [FIRFieldValue fieldValueForArrayUnion:@[ @"tag" ]],
    @"bar.baz" :
        [FIRFieldValue fieldValueForArrayUnion:@[ @YES, @{@"nested" : @{@"a" : @[ @1, @2 ]}} ]]
  },
                                                     {});
  XCTAssertEqual(patchMutation.field_transforms().size(), 2u);

  SetMutation setMutation = FSTTestSetMutation(@"collection/key", @{
    @"foo" : [FIRFieldValue fieldValueForArrayUnion:@[ @"tag" ]],
    @"bar" : [FIRFieldValue fieldValueForArrayUnion:@[ @YES, @{@"nested" : @{@"a" : @[ @1, @2 ]}} ]]
  });
  XCTAssertEqual(setMutation.field_transforms().size(), 2u);

  const FieldTransform &patchFirst = patchMutation.field_transforms()[0];
  XCTAssertEqual(patchFirst.path(), FieldPath({"foo"}));
  const FieldTransform &setFirst = setMutation.field_transforms()[0];
  XCTAssertEqual(setFirst.path(), FieldPath({"foo"}));
  {
    std::vector<FieldValue> expectedElements{FSTTestFieldValue(@"tag")};
    ArrayTransform expected(TransformOperation::Type::ArrayUnion, expectedElements);
    XCTAssertEqual(static_cast<const ArrayTransform &>(patchFirst.transformation()), expected);
    XCTAssertEqual(static_cast<const ArrayTransform &>(setFirst.transformation()), expected);
  }

  const FieldTransform &patchSecond = patchMutation.field_transforms()[1];
  XCTAssertEqual(patchSecond.path(), FieldPath({"bar", "baz"}));
  const FieldTransform &setSecond = setMutation.field_transforms()[1];
  XCTAssertEqual(setSecond.path(), FieldPath({"bar"}));
  {
    std::vector<FieldValue> expectedElements {
      FSTTestFieldValue(@YES), FSTTestFieldValue(@{@"nested" : @{@"a" : @[ @1, @2 ]}})
    };
    ArrayTransform expected(TransformOperation::Type::ArrayUnion, expectedElements);
    XCTAssertEqual(static_cast<const ArrayTransform &>(patchSecond.transformation()), expected);
    XCTAssertEqual(static_cast<const ArrayTransform &>(setSecond.transformation()), expected);
  }
}

- (void)testCreatesArrayRemoveTransforms {
  PatchMutation patchMutation = FSTTestPatchMutation(@"collection/key", @{
    @"foo" : [FIRFieldValue fieldValueForArrayRemove:@[ @"tag" ]],
  },
                                                     {});
  XCTAssertEqual(patchMutation.field_transforms().size(), 1u);

  SetMutation setMutation = FSTTestSetMutation(@"collection/key", @{
    @"foo" : [FIRFieldValue fieldValueForArrayRemove:@[ @"tag" ]],
  });
  XCTAssertEqual(patchMutation.field_transforms().size(), 1u);

  const FieldTransform &patchFirst = patchMutation.field_transforms()[0];
  XCTAssertEqual(patchFirst.path(), FieldPath({"foo"}));
  const FieldTransform &setFirst = setMutation.field_transforms()[0];
  XCTAssertEqual(setFirst.path(), FieldPath({"foo"}));
  {
    std::vector<FieldValue> expectedElements{FSTTestFieldValue(@"tag")};
    const ArrayTransform expected(TransformOperation::Type::ArrayRemove, expectedElements);
    XCTAssertEqual(static_cast<const ArrayTransform &>(patchFirst.transformation()), expected);
    XCTAssertEqual(static_cast<const ArrayTransform &>(setFirst.transformation()), expected);
  }
}

@end
