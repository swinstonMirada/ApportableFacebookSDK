/*
 * Copyright 2010-present Facebook.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBSession+Internal.h"
#import "FBSessionIntegrationTests.h"
#import "FBTestSession.h"
#import "FBRequest.h"
#import "FBGraphUser.h"
#import "FBTestBlocker.h"
#import "FBUtility.h"
#import "FBError.h"
#import "FBSessionTokenCachingStrategy.h"

#if defined(FACEBOOKSDK_SKIP_SESSION_TESTS)

#pragma message ("warning: Skipping FBSessionTests")

#else

#pragma mark - Test suite

@implementation FBSessionIntegrationTests

- (void)testSessionBasic
{
    FBConditionalLog(NO, @"Testing conditional %@", @"log");
    FBConditionalLog(NO, @"Testing conditional log");
    FBConditionalLog(YES, nil, @"Testing conditional log");

    // create valid
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];

    FBTestSession *session = [FBTestSession sessionWithSharedUserWithPermissions:nil];
    [session openWithCompletionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        [blocker signal];
    }];

    [blocker wait];

    XCTAssertTrue(session.isOpen, @"Session should be valid, and is not");

    FBRequest *request = [[FBRequest alloc] initWithSession:session
                                                   graphPath:@"me"];
    [request startWithCompletionHandler:
     ^(FBRequestConnection *connection, id<FBGraphUser> me, NSError *error) {
         XCTAssertTrue(me.id.length > 0, @"user id should be non-empty");
         [blocker signal];
     }];

    [blocker wait];

    [session close];
}

- (void)testSessionInvalidate
{
    // create valid
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];

    __block BOOL wasNotifiedOfInvalid = NO;
    FBTestSession *session = [FBTestSession sessionWithPrivateUserWithPermissions:nil];
    [session openWithCompletionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        if (status == FBSessionStateClosed) {
            wasNotifiedOfInvalid = YES;
        }
        [blocker signal];
    }];
    [blocker wait];

    XCTAssertTrue(session.isOpen, @"Session should be open, and is not");

    __block NSString *userID = nil;
    FBRequest *request1 = [[FBRequest alloc] initWithSession:session
                                                    graphPath:@"me"];
    [request1 startWithCompletionHandler:
     ^(FBRequestConnection *connection, id<FBGraphUser> me, NSError *error) {
         userID = me.id;
         XCTAssertTrue(userID.length > 0, @"user id should be non-empty");
         [blocker signal];
     }];

    [blocker wait];

    // use FBRequest to create an NSURLRequest
    FBRequest *temp = [[FBRequest alloc] initWithSession:session
                                               graphPath:userID
                                              parameters:[NSDictionary dictionaryWithObjectsAndKeys:
                                                          @"delete", @"method",
                                                          nil]
                                              HTTPMethod:nil];
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];
    [connection addRequest:temp completionHandler:nil];
    NSURLRequest *urlRequest = connection.urlRequest;
    userID = nil;
    connection = nil;
    temp = nil;

    // synchronously delete the user
    NSURLResponse *response;
    NSError *error = nil;
    NSData *data;
    data = [NSURLConnection sendSynchronousRequest:urlRequest
                                 returningResponse:&response
                                             error:&error];
    // if !data or if data == false, log
    NSString *body = !data ? nil : [[NSString alloc] initWithData:data
                                                          encoding:NSUTF8StringEncoding];
    XCTAssertTrue([body isEqualToString:@"true"], @"body should return 'true'");

    FBRequest *request2 = [[FBRequest alloc] initWithSession:session
                                                    graphPath:@"me"];
    [request2 startWithCompletionHandler:
     ^(FBRequestConnection *connection, id<FBGraphUser> me, NSError *error) {
         XCTAssertTrue(error != nil, @"response should be an error due to deleted user");
         [blocker signal];
     }];

    XCTAssertFalse(wasNotifiedOfInvalid, @"should not have invalidated the token yet");
    [blocker wait];
    XCTAssertTrue(wasNotifiedOfInvalid, @"should have invalidated the token by now");

    [session close];
}

- (void)testSessionOpenFromAccessToken
{
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    __block BOOL expectClosed = NO;

    // Open a test session normally for accesstoken/appid
    FBTestSession *normalSession = [FBTestSession sessionWithPrivateUserWithPermissions:nil];
    [normalSession openWithCompletionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        XCTAssertTrue(session.state == FBSessionStateOpen || expectClosed, @"Expected open session: %@, %@", session, error);
        [blocker signal];
    }];
    [blocker wait];

    // Now construct the actual session under test (target) and open with the access token.
    // Note just hack in expiration time of 3600 for the test.
    FBSession *target = [[FBSession alloc] initWithAppID:normalSession.appID permissions:nil
                                         defaultAudience:FBSessionDefaultAudienceFriends
                                         urlSchemeSuffix:nil
                                      tokenCacheStrategy:[FBSessionTokenCachingStrategy nullCacheInstance]];

    FBAccessTokenData *tokenDataCopy = [normalSession.accessTokenData copy];
    BOOL openResult = [target openFromAccessTokenData:tokenDataCopy
                                    completionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
                                        XCTAssertTrue(status == FBSessionStateOpen || expectClosed, @"status is :%d , error:%@:", status, error);
                                        [blocker signal];
                                    }];
    XCTAssertTrue(openResult, @"expected openResult=YES");
    [blocker wait];

    //final check, just do a request for me with the target
    FBRequest *request = [[FBRequest alloc] initWithSession:target
                                                   graphPath:@"me"];
    [request startWithCompletionHandler:
     ^(FBRequestConnection *connection, id<FBGraphUser> me, NSError *error) {
         XCTAssertTrue(me.id.length > 0, @"user id should be non-empty. error:%@", error);
         [blocker signal];
     }];

    [blocker wait];

    expectClosed = YES;
    [target close];
    [normalSession close];
    tokenDataCopy = nil;
    target = nil;
}

- (void)testSessionOpenFromAccessTokenAlreadyOpen
{
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    __block BOOL expectClosed = NO;

    // Open a test session normally for accesstoken/appid
    FBTestSession *target = [FBTestSession sessionWithPrivateUserWithPermissions:nil];
    [target openWithCompletionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        XCTAssertTrue(session.state == FBSessionStateOpen || expectClosed, @"Expected open session: %@, %@", session, error);
        [blocker signal];
    }];
    [blocker wait];

    FBAccessTokenData *tokenDataCopy = [target.accessTokenData copy];

    //Now try to open it again
    XCTAssertThrowsSpecific([target openFromAccessTokenData:tokenDataCopy
                                         completionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
                                             XCTFail(@"Completion handler was unexpectedly invoked for session: %@", session);
                                         }],
                           NSException,
                           "%@", FBInvalidOperationException);

    tokenDataCopy = nil;
}

- (void)testSessionOpenWillRefreshPermissions
{
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    __block BOOL expectClosed = NO;

    // Open a test session normally for accesstoken/appid
    FBTestSession *normalSession = [FBTestSession sessionWithPrivateUserWithPermissions:nil];
    [normalSession openWithCompletionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        XCTAssertTrue(session.state == FBSessionStateOpen || expectClosed, @"Expected open session: %@, %@", session, error);
        [blocker signal];
    }];
    XCTAssertTrue([blocker waitWithTimeout:60], @"blocker timed out");
    XCTAssertTrue([normalSession shouldRefreshPermissions], @"expected need for permissions refresh");

    expectClosed = YES;
    [normalSession close];
}

- (void)testSessionOpenFromAccessTokenWillRefreshPermissions
{
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    __block BOOL expectClosed = NO;

    // Open a test session normally for accesstoken/appid
    FBTestSession *normalSession = [FBTestSession sessionWithPrivateUserWithPermissions:nil];
    [normalSession openWithCompletionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        XCTAssertTrue(session.state == FBSessionStateOpen || expectClosed, @"Expected open session: %@, %@", session, error);
        [blocker signal];
    }];
    XCTAssertTrue([blocker waitWithTimeout:60], @"blocker timed out");

    // Now construct the actual session under test (target) and open with the access token.
    // Note just hack in expiration time of 3600 for the test.
    FBSession *target = [[FBSession alloc] initWithAppID:normalSession.appID permissions:nil
                                         defaultAudience:FBSessionDefaultAudienceFriends
                                         urlSchemeSuffix:nil
                                      tokenCacheStrategy:[FBSessionTokenCachingStrategy nullCacheInstance]];

    FBAccessTokenData *tokenDataCopy = [normalSession.accessTokenData copy];
    BOOL openResult = [target openFromAccessTokenData:tokenDataCopy
                                    completionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
                                        XCTAssertTrue(status == FBSessionStateOpen || expectClosed, @"status is :%d , error:%@:", status, error);
                                        [blocker signal];
                                    }];
    XCTAssertTrue(openResult, @"expected openResult=YES");
    XCTAssertTrue([blocker waitWithTimeout:10], @"blocker timed out");

    // Check the refresh permissions state
    XCTAssertTrue([target shouldRefreshPermissions], @"expected need for permissions refresh");

    //now do a request for me with the target which will refresh the permissions
    FBRequest *request = [[FBRequest alloc] initWithSession:target
                                                   graphPath:@"me"];
    [request startWithCompletionHandler:
     ^(FBRequestConnection *connection, id<FBGraphUser> me, NSError *error) {
         XCTAssertTrue(me.id.length > 0, @"user id should be non-empty. error:%@", error);
         [blocker signal];
     }];

    XCTAssertTrue([blocker waitWithTimeout:30], @"blocker timed out requesting me");

    // now make sure the refresh permissions is satisfied.
    XCTAssertFalse([target shouldRefreshPermissions], @"did NOT expect need for permissions refresh");

    expectClosed = YES;
    [target close];
    [normalSession close];
}


@end

#endif

