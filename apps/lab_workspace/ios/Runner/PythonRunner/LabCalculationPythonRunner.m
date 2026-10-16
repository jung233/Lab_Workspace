#import "LabCalculationPythonRunner.h"

#if __has_include(<Python/Python.h>)
#import <Python/Python.h>
#define LAB_HAS_EMBEDDED_PYTHON 1
#else
#define LAB_HAS_EMBEDDED_PYTHON 0
#endif

static NSString * const LabCalculationPythonRunnerErrorDomain =
    @"org.labworkspace.calculation-python";
static const NSUInteger LabCalculationMaxRequestBytes = 32 * 1024 * 1024;

#if LAB_HAS_EMBEDDED_PYTHON
static BOOL LabPythonInitialized = NO;
static BOOL LabPythonInitializationFailed = NO;
#endif

@implementation LabCalculationPythonRunner

+ (BOOL)isAvailable {
#if LAB_HAS_EMBEDDED_PYTHON
  NSBundle *mainBundle = NSBundle.mainBundle;
  NSString *resourcePath = mainBundle.resourcePath;
  NSString *pythonHome = [resourcePath stringByAppendingPathComponent:@"python"];
  NSString *stdlib = [pythonHome stringByAppendingPathComponent:@"lib/python3.15/os.py"];
  NSString *dynamicModules = [pythonHome stringByAppendingPathComponent:@"lib/python3.15/lib-dynload"];
  NSString *appModule = [resourcePath stringByAppendingPathComponent:
      @"app/mobile/calculation_mobile_bridge.py"];
  NSString *pythonFramework = [mainBundle.bundlePath
      stringByAppendingPathComponent:@"Frameworks/Python.framework"];
  BOOL isDirectory = NO;
  return [[NSFileManager defaultManager] fileExistsAtPath:stdlib] &&
      [[NSFileManager defaultManager] fileExistsAtPath:dynamicModules isDirectory:&isDirectory] &&
      isDirectory &&
      [[NSFileManager defaultManager] fileExistsAtPath:appModule] &&
      [[NSFileManager defaultManager] fileExistsAtPath:pythonFramework isDirectory:&isDirectory] &&
      isDirectory;
#else
  return NO;
#endif
}

+ (NSString *)probeJSONRPC {
  NSString *request = @"{\"jsonrpc\":\"2.0\",\"id\":\"probe\",\"method\":\"probe\",\"params\":{}}";
  NSError *error = nil;
  NSString *response = [self handleJSONRPC:request error:&error];
  if (response != nil) {
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
    id decoded = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([decoded isKindOfClass:NSDictionary.class] &&
        ((NSDictionary *)decoded)[@"error"] == nil) {
      return response;
    }
  }
  return [self unavailableProbeJSONRPC];
}

+ (nullable NSString *)handleJSONRPC:(NSString *)requestJSON error:(NSError * _Nullable * _Nullable)error {
  NSData *requestData = [requestJSON dataUsingEncoding:NSUTF8StringEncoding];
  if (requestData == nil || requestData.length > LabCalculationMaxRequestBytes) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:LabCalculationPythonRunnerErrorDomain
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: @"JSON-RPC request exceeds 32 MiB."}];
    }
    return nil;
  }
#if LAB_HAS_EMBEDDED_PYTHON
  @synchronized(self) {
    NSError *initializationError = nil;
    if (![self initializePython:&initializationError]) {
      if (error != NULL) *error = initializationError;
      return nil;
    }

    PyGILState_STATE gilState = PyGILState_Ensure();
    NSString *resultString = nil;
    PyObject *request = PyUnicode_DecodeUTF8(
        (const char *)requestData.bytes, (Py_ssize_t)requestData.length, "strict");
    PyObject *runtimeTarget = request == NULL ? NULL : PyUnicode_FromString("ios");
    PyObject *module = request == NULL ? NULL : PyImport_ImportModule("mobile.calculation_mobile_bridge");
    PyObject *function = module == NULL ? NULL : PyObject_GetAttrString(module, "handle_json");
    PyObject *result = function == NULL || request == NULL || runtimeTarget == NULL
        ? NULL
        : PyObject_CallFunctionObjArgs(function, request, runtimeTarget, NULL);
    if (result != NULL && PyUnicode_Check(result)) {
      Py_ssize_t resultLength = 0;
      const char *utf8Result = PyUnicode_AsUTF8AndSize(result, &resultLength);
      if (utf8Result != NULL) {
        resultString = [[NSString alloc] initWithBytes:utf8Result
                                               length:(NSUInteger)resultLength
                                             encoding:NSUTF8StringEncoding];
      }
    }
    if (runtimeTarget != NULL) Py_DECREF(runtimeTarget);
    if (request != NULL) Py_DECREF(request);
    if (result != NULL) Py_DECREF(result);
    if (function != NULL) Py_DECREF(function);
    if (module != NULL) Py_DECREF(module);
    if (resultString == nil) {
      PyErr_Clear();
      if (error != NULL) {
        *error = [NSError errorWithDomain:LabCalculationPythonRunnerErrorDomain
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     @"The bundled calculation JSON-RPC handler failed."}];
      }
    }
    PyGILState_Release(gilState);
    return resultString;
  }
#else
  if (error != NULL) {
    *error = [NSError errorWithDomain:LabCalculationPythonRunnerErrorDomain
                                 code:3
                             userInfo:@{NSLocalizedDescriptionKey:
                                 @"The trusted embedded Python framework is not linked."}];
  }
  return nil;
#endif
}

#if LAB_HAS_EMBEDDED_PYTHON
+ (BOOL)initializePython:(NSError **)error {
  if (LabPythonInitialized) return YES;
  if (LabPythonInitializationFailed || ![self isAvailable]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:LabCalculationPythonRunnerErrorDomain
                                   code:4
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"The trusted embedded Python runtime is unavailable."}];
    }
    return NO;
  }

  NSBundle *mainBundle = NSBundle.mainBundle;
  NSString *resourcePath = mainBundle.resourcePath;
  NSString *pythonHome = [resourcePath stringByAppendingPathComponent:@"python"];
  NSString *pythonLib = [pythonHome stringByAppendingPathComponent:@"lib/python3.15"];
  NSString *dynamicModules = [pythonLib stringByAppendingPathComponent:@"lib-dynload"];
  NSString *appPath = [resourcePath stringByAppendingPathComponent:@"app"];
  NSString *pythonPath = [NSString stringWithFormat:@"%@:%@:%@", pythonLib, dynamicModules, appPath];
  setenv("PYTHONHOME", pythonHome.fileSystemRepresentation, 1);
  setenv("PYTHONPATH", pythonPath.UTF8String, 1);

  PyPreConfig preConfig;
  PyPreConfig_InitPythonConfig(&preConfig);
  preConfig.utf8_mode = 1;
  PyStatus status = Py_PreInitialize(&preConfig);
  if (PyStatus_Exception(status)) {
    LabPythonInitializationFailed = YES;
    if (error != NULL) {
      *error = [self pythonStatusError:status code:5];
    }
    return NO;
  }

  PyConfig config;
  PyConfig_InitPythonConfig(&config);
  config.buffered_stdio = 0;
  config.write_bytecode = 0;
  config.install_signal_handlers = 1;
  config.use_system_logger = 1;
  PyStatus homeStatus = PyConfig_SetBytesString(&config, &config.home, pythonHome.fileSystemRepresentation);
  PyStatus pathStatus = PyStatus_Exception(homeStatus)
      ? homeStatus
      : PyConfig_SetBytesString(&config, &config.pythonpath_env, pythonPath.UTF8String);
  status = PyStatus_Exception(pathStatus)
      ? pathStatus
      : Py_InitializeFromConfig(&config);
  PyConfig_Clear(&config);
  if (PyStatus_Exception(status)) {
    LabPythonInitializationFailed = YES;
    if (error != NULL) {
      *error = [self pythonStatusError:status code:6];
    }
    return NO;
  }
  LabPythonInitialized = YES;
  PyEval_SaveThread();
  return YES;
}

+ (NSError *)pythonStatusError:(PyStatus)status code:(NSInteger)code {
  NSString *message = status.err_msg == NULL
      ? @"CPython initialization failed."
      : [NSString stringWithUTF8String:status.err_msg];
  return [NSError errorWithDomain:LabCalculationPythonRunnerErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey: message ?: @"CPython initialization failed."}];
}
#endif

+ (NSString *)unavailableProbeJSONRPC {
  NSDictionary *capabilities = @{
    @"executor_id": @"trusted-python-ios-v2",
    @"platform": @"ios",
    @"available": @NO,
    @"bundled_executor": @NO,
    @"python_runtime": @"unavailable",
    @"supported_operations": @[],
    @"supports_cancellation": @NO,
    @"unsupported_reason": @"TRUSTED_PYTHON_RUNTIME_UNAVAILABLE",
  };
  NSDictionary *response = @{@"jsonrpc": @"2.0", @"id": @"probe", @"result": capabilities};
  NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
  return data == nil ? @"{}" : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@end
