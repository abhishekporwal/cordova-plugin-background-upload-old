#import "FileUploader.h"
#import "AppDelegate+upload.h"
@interface FileUploader()
@property (nonatomic, strong) NSMutableDictionary* responsesData;
@property (nonatomic, strong) AFURLSessionManager *manager;
@end

@implementation FileUploader
static NSInteger _parallelUploadsLimit = 1;
static FileUploader *singletonObject = nil;
static NSString * kUploadUUIDStrPropertyKey = @"com.spoon.plugin-background-upload.UUID";
+ (instancetype)sharedInstance{
    if (!singletonObject)
        singletonObject = [[FileUploader alloc] init];
    return singletonObject;
}
- (id)init{
    self = [super init];
    if (self == nil)
        return nil;
    [UploadEvent setupStorage];
    self.responsesData = [[NSMutableDictionary alloc] init];
    NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
    configuration.HTTPMaximumConnectionsPerHost = FileUploader.parallelUploadsLimit;
    self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    __weak FileUploader *weakSelf = self;
    [self.manager setTaskDidCompleteBlock:^(NSURLSession * _Nonnull session, NSURLSessionTask * _Nonnull task, NSError * _Nullable error) {
        NSString* uploadId = [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:task.originalRequest];
        UploadEvent* event = [[UploadEvent alloc] init];
        event.uploadId = uploadId;
        if (!error){
            event.state = @"SUCCESS";
            event.responseStatusCode = ((NSHTTPURLResponse *)task.response).statusCode;
            NSData* serverData = weakSelf.responsesData[@(task.taskIdentifier)];
            event.serverResponse = serverData ? [[NSString alloc] initWithData:serverData encoding:NSUTF8StringEncoding] : @"";
            [weakSelf.responsesData removeObjectForKey:@(task.taskIdentifier)];
            NSLog(@"[CD]task did complete with success %@ response: %@",uploadId,event.serverResponse);
        } else {
            event.state = @"FAILED";
            event.error = error.localizedDescription;
            event.errorCode = error.code;
            NSLog(@"[CD]task did fail %@ %@",uploadId , error.localizedDescription);
        }
        NSDictionary* representation = @{
                                         @"state": event.state,
                                         @"responseStatusCode": @(event.responseStatusCode),
                                         @"serverResponse": event.serverResponse,
                                         @"uploadId": uploadId,
                                         @"error": event.error,
                                         @"errorCode": @(event.errorCode)
                                         };
        NSData * jsonData = [NSJSONSerialization dataWithJSONObject:representation options:0 error:nil];
        event.data = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [event save];
        [weakSelf.delegate uploadManagerDidCompleteUpload:event];
        [[NSFileManager defaultManager] removeItemAtURL:[weakSelf tempFilePathForUpload:uploadId] error:nil];
    }];
    
    [self.manager setDataTaskDidReceiveDataBlock:^(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSData * _Nonnull data) {
        NSMutableData *responseData = weakSelf.responsesData[@(dataTask.taskIdentifier)];
        if (!responseData) {
            weakSelf.responsesData[@(dataTask.taskIdentifier)] = [NSMutableData dataWithData:data];
        } else {
            [responseData appendData:data];
        }
    }];
    
    [self.manager setDidFinishEventsForBackgroundURLSessionBlock:^(NSURLSession * _Nonnull session) {
        NSLog(@"[CD]setDidFinishEventsForBackgroundURLSessionBlock block: %@",session);
        AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
        if (appDelegate.backgroundCompletionBlock) {
            void (^completionHandler)(void) = appDelegate.backgroundCompletionBlock;
            appDelegate.backgroundCompletionBlock = nil;
            completionHandler();
        }
    }];
    return self;
}
+(NSInteger)parallelUploadsLimit {
  return _parallelUploadsLimit;
}

+(void)setParallelUploadsLimit:(NSInteger)value {
    _parallelUploadsLimit = value;
}

-(NSURL*)tempFilePathForUpload:(NSString*)uploadId{
    NSString* path = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0];
    return [NSURL fileURLWithPath:[path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.request",uploadId]]];
}
-(void)writeMultipartDataToTempFile: (NSURL*)tempFilePath
                                url:(NSURL *)url
                           uploadId:(NSString*)uploadId
                            fileURL:(NSURL *)fileURL
                            headers:(NSDictionary*)headers
                         parameters:(NSDictionary*)parameters
                            fileKey:(NSString*)fileKey
                  completionHandler:(void (^)(NSError* error, NSMutableURLRequest* request))handler{
    AFHTTPRequestSerializer *serializer = [AFHTTPRequestSerializer serializer];
    NSError *error;
    NSMutableURLRequest *request =
    [serializer multipartFormRequestWithMethod:@"POST"
                                     URLString:url.absoluteString
                                    parameters:parameters
                     constructingBodyWithBlock:^(id<AFMultipartFormData> formData){
                         NSString *filename = [fileURL.absoluteString lastPathComponent];
                         NSData * data = [NSData dataWithContentsOfURL:fileURL];
                         [formData appendPartWithFileData:data name:fileKey fileName:filename mimeType:@"application/octet-stream"];
                     }
                                         error:&error];
    if (error)
        return handler(error, nil);
    for (NSString *key in headers) {
        [request setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }
    [NSURLProtocol setProperty:uploadId forKey:kUploadUUIDStrPropertyKey inRequest:request];
    [serializer requestWithMultipartFormRequest:request writingStreamContentsToFile:tempFilePath completionHandler:^(NSError *error) {
        if (!error && ![[NSFileManager defaultManager] fileExistsAtPath:tempFilePath.path])
            error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        handler(error, request);
    }];
}
-(void)addUpload:(NSDictionary *)payload completionHandler:(void (^)(NSError* error))handler{
    __weak FileUploader *weakSelf = self;
    NSURL *tempFilePath = [self tempFilePathForUpload:payload[@"id"]];
    [self writeMultipartDataToTempFile:tempFilePath
                                   url:[NSURL URLWithString:payload[@"serverUrl"]]
                              uploadId:payload[@"id"]
                               fileURL:[NSURL fileURLWithPath:payload[@"filePath"]]
                               headers: payload[@"headers"]
                            parameters:payload[@"parameters"]
                               fileKey:payload[@"fileKey"]
                     completionHandler:^(NSError *error, NSMutableURLRequest *request) {
                         if (error)
                             return handler(error);
                         __block double lastProgressTimeStamp = 0;
                            NSLog(@"[CD] uploadTaskWithRequest %@",request);
                             [[weakSelf.manager uploadTaskWithRequest:request
                                                             fromFile:tempFilePath
                                                             progress:^(NSProgress * _Nonnull uploadProgress) {
                                                                 float roundedProgress = roundf(10 * (uploadProgress.fractionCompleted*100)) / 10.0;
                                                                 NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
                                                                 if (currentTimestamp - lastProgressTimeStamp >= 1){
                                                                     lastProgressTimeStamp = currentTimestamp;
                                                                     [weakSelf.delegate uploadManagerDidReceiveProgress:roundedProgress
                                                                                                              forUpload:[NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:request]];
                                                                 }
                                                             }
                                                    completionHandler:nil] resume];
                        [[NSFileManager defaultManager] removeItemAtURL:[weakSelf tempFilePathForUpload:payload[@"id"]] error:nil];
                     }];
}

-(void)removeUpload:(NSString*)uploadId{
    NSURLSessionUploadTask *correspondingTask =
    [[self.manager.uploadTasks filteredArrayUsingPredicate: [NSPredicate predicateWithBlock:^BOOL(NSURLSessionUploadTask* task, NSDictionary *bindings) {
        NSString* currentId = [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:task.originalRequest];
        return [uploadId isEqualToString:currentId];
    }]] firstObject];
    [correspondingTask cancel];
}

-(void)acknowledgeEventReceived:(NSString*)eventId{
    [[UploadEvent eventWithId:eventId] destroy];
}
@end
