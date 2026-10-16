#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes only the fixed mobile JSON-RPC module shipped inside the app.
/// The native host should call this from its dedicated calculation executor.
@interface LabCalculationPythonRunner : NSObject

+ (BOOL)isAvailable;
+ (NSString *)probeJSONRPC;
+ (nullable NSString *)handleJSONRPC:(NSString *)requestJSON error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
