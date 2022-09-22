//------------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//------------------------------------------------------------------------------

#import "MSQASignIn.h"

#import <Foundation/Foundation.h>
#import <MSAL/MSAL.h>

#import "MSQAAccountData_Private.h"
#import "MSQAConfiguration.h"
#import "MSQAPhotoFetcher.h"
#import "MSQASilentTokenParameters.h"

#define DEFAULT_SCOPES @[ @"User.Read" ]

static NSString *const kAuthorityURL =
    @"https://login.microsoftonline.com/consumers";

static NSString *const kMSALNotConfiguredError = @"MSQASignIn not configured";

static NSString *const kEmptyScopesError = @"Empty scopes array";

NS_ASSUME_NONNULL_BEGIN

@implementation MSQASignIn {
  MSALPublicClientApplication *_msalPublicClientApplication;
  MSQAConfiguration *_configuration;
}

#pragma mark - Public methods

- (instancetype)initWithConfiguration:(MSQAConfiguration *)configuration
                                error:(NSError *_Nullable *_Nullable)error {
  if (!(self = [super init])) {
    return nil;
  }
  return [self initPrivateWithConfiguration:configuration error:error];
}

- (BOOL)handleURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication {
  return [MSALPublicClientApplication handleMSALResponse:url
                                       sourceApplication:sourceApplication];
}

- (void)acquireTokenWithParameters:(MSQAInteractiveTokenParameters *)parameters
                   completionBlock:(MSQACompletionBlock)completionBlock {
  parameters.completionBlockQueue = dispatch_get_main_queue();

  [_msalPublicClientApplication
      acquireTokenWithParameters:parameters
                 completionBlock:^(MSALResult *result, NSError *error) {
                   [MSQASignIn callCompletionBlock:completionBlock
                                    withMSALResult:result
                                             error:error];
                 }];
}

- (void)acquireTokenSilentWithParameters:(MSQASilentTokenParameters *)parameters
                         completionBlock:(MSQACompletionBlock)completionBlock {

  MSALParameters *paramsForGetCurrentAccount = [MSALParameters new];
  paramsForGetCurrentAccount.completionBlockQueue = dispatch_get_main_queue();

  [_msalPublicClientApplication
      getCurrentAccountWithParameters:paramsForGetCurrentAccount
                      completionBlock:^(MSALAccount *_Nullable account,
                                        MSALAccount *_Nullable previousAccount,
                                        NSError *_Nullable error) {
                        if (!account || error) {
                          completionBlock(nil, error);
                          return;
                        }
                        [self acquireTokenSilentWithParameters:parameters
                                                       account:account
                                               completionBlock:completionBlock];
                      }];
}

- (void)getCurrentAccountWithCompletionBlock:
    (MSQACompletionBlock)completionBlock {
  MSALParameters *parameters = [MSALParameters new];
  parameters.completionBlockQueue = dispatch_get_main_queue();

  [_msalPublicClientApplication
      getCurrentAccountWithParameters:parameters
                      completionBlock:^(MSALAccount *_Nullable account,
                                        MSALAccount *_Nullable previousAccount,
                                        NSError *_Nullable error) {
                        if (!account || error) {
                          completionBlock(nil, error);
                          return;
                        }

                        MSQAAccountData *accountData = [[MSQAAccountData alloc]
                            initWithFullName:account.accountClaims[@"name"]
                                    userName:account.username
                                      userId:[MSQASignIn
                                                 getUserIdFromObjectId:
                                                     account.homeAccountId
                                                         .objectId]
                                     idToken:nil
                                 accessToken:nil];
                        completionBlock(accountData, nil);
                      }];
}

- (void)signOutWithCompletionBlock:
    (void (^)(NSError *_Nullable error))completionBlock {
  MSALParameters *parameters = [MSALParameters new];
  parameters.completionBlockQueue = dispatch_get_main_queue();

  [_msalPublicClientApplication
      getCurrentAccountWithParameters:parameters
                      completionBlock:^(MSALAccount *_Nullable account,
                                        MSALAccount *_Nullable previousAccount,
                                        NSError *_Nullable error) {
                        if (account && !error) {
                          NSError *localError = nil;
                          [self->_msalPublicClientApplication
                              removeAccount:account
                                      error:&localError];
                          completionBlock(localError);
                          return;
                        }
                        completionBlock(error);
                      }];
}

- (void)signInWithViewController:(UIViewController *)controller
                 completionBlock:(MSQACompletionBlock)completionBlock {
  MSQASilentTokenParameters *parameters =
      [[MSQASilentTokenParameters alloc] initWithScopes:@[ @"User.Read" ]];
  [self
      acquireTokenSilentWithParameters:parameters
                       completionBlock:^(MSQAAccountData *_Nullable account,
                                         NSError *_Nullable error) {
                         if (account && !error) {
                           [self
                               continueToFetchPhotoWithAccount:account
                                               completionBlock:completionBlock];
                           return;
                         }

                         [self
                             acquireTokenWithParameters:
                                 [MSQASignIn
                                     createInteractiveTokenParametersWithController:
                                         controller]
                                        completionBlock:^(
                                            MSQAAccountData *_Nullable account,
                                            NSError *_Nullable error) {
                                          if (account && !error) {
                                            [self
                                                continueToFetchPhotoWithAccount:
                                                    account
                                                                completionBlock:
                                                                    completionBlock];
                                            return;
                                          }
                                          completionBlock(nil, error);
                                        }];
                       }];
}

#pragma mark - Class methods

+ (MSALInteractiveTokenParameters *)
    createInteractiveTokenParametersWithController:
        (UIViewController *)controller {
  MSALWebviewParameters *webParameters = [[MSALWebviewParameters alloc]
      initWithAuthPresentationViewController:controller];
  MSALInteractiveTokenParameters *parameters =
      [[MSALInteractiveTokenParameters alloc] initWithScopes:DEFAULT_SCOPES
                                           webviewParameters:webParameters];
  return parameters;
}

+ (MSQAAccountData *)createMQAAccountDataFromMSALResult:(MSALResult *)result {
  MSALAccount *account = result.account;
  NSString *userId =
      [MSQASignIn getUserIdFromObjectId:account.homeAccountId.objectId];
  return
      [[MSQAAccountData alloc] initWithFullName:account.accountClaims[@"name"]
                                       userName:account.username
                                         userId:userId
                                        idToken:result.idToken
                                    accessToken:result.accessToken];
}

+ (NSString *)getUserIdFromObjectId:(NSString *)objectId {
  // The `objectId` format is "00000000-0000-xxxx-xxxx-xxxxxxxx", so we need to
  // remove the character "-" first.
  NSString *str = [objectId stringByReplacingOccurrencesOfString:@"-"
                                                      withString:@""];
  // Remove leading zeros and return.
  return [str stringByReplacingOccurrencesOfString:@"^0+"
                                        withString:@""
                                           options:NSRegularExpressionSearch
                                             range:NSMakeRange(0, str.length)];
}

+ (void)callCompletionBlockAsync:(MSQACompletionBlock)completionBlock
                        errorStr:(NSString *)errStr {
  [MSQASignIn runBlockAsyncOnMainThread:^{
    completionBlock(nil, [NSError errorWithDomain:errStr code:0 userInfo:nil]);
  }];
}

+ (void)callCompletionBlock:(MSQACompletionBlock)completionBlock
             withMSALResult:(MSALResult *)result
                      error:(NSError *)error {
  if (result && !error) {
    completionBlock([MSQASignIn createMQAAccountDataFromMSALResult:result],
                    nil);
    return;
  }

  completionBlock(nil, error);
}

+ (void)runBlockAsyncOnMainThread:(void (^)(void))block {
  dispatch_async(dispatch_get_main_queue(), ^{
    block();
  });
}

#pragma mark - Private methods

- (void)acquireTokenSilentWithParameters:(MSQASilentTokenParameters *)parameters
                                 account:(MSALAccount *_Nullable)account
                         completionBlock:(MSQACompletionBlock)completionBlock {
  MSALSilentTokenParameters *silentTokenParameters =
      [[MSALSilentTokenParameters alloc] initWithScopes:parameters.scopes
                                                account:account];
  silentTokenParameters.completionBlockQueue = dispatch_get_main_queue();

  [_msalPublicClientApplication
      acquireTokenSilentWithParameters:silentTokenParameters
                       completionBlock:^(MSALResult *result, NSError *error) {
                         [MSQASignIn callCompletionBlock:completionBlock
                                          withMSALResult:result
                                                   error:error];
                       }];
}

- (void)continueToFetchPhotoWithAccount:(MSQAAccountData *)account
                        completionBlock:(MSQACompletionBlock)completionBlock {
  [MSQAPhotoFetcher fetchPhotoWithToken:account.accessToken
                        completionBlock:^(NSString *_Nullable base64Photo,
                                          NSError *_Nullable error) {
                          if (base64Photo) {
                            account.base64Photo = base64Photo;
                          }
                          [MSQASignIn runBlockAsyncOnMainThread:^{
                            completionBlock(account, nil);
                          }];
                        }];
}

- (instancetype)initPrivateWithConfiguration:(MSQAConfiguration *)configuration
                                       error:(NSError *_Nullable *_Nullable)
                                                 error {
  MSALAuthority *authority =
      [MSALAuthority authorityWithURL:[NSURL URLWithString:kAuthorityURL]
                                error:nil];
  MSALPublicClientApplicationConfig *msalConfig =
      [[MSALPublicClientApplicationConfig alloc]
          initWithClientId:configuration.clientID
               redirectUri:nil
                 authority:authority];
  NSError *localError = nil;
  _msalPublicClientApplication =
      [[MSALPublicClientApplication alloc] initWithConfiguration:msalConfig
                                                           error:&localError];

  if (localError) {
    if (error) {
      *error = localError;
    }
    return nil;
  }
  _configuration = configuration;
  return self;
}

@end

NS_ASSUME_NONNULL_END
