//
//  EncryptionBridge.m
//  EncryptedSync
//
//  Created by Simon Maddox on 19/09/2016.
//  Copyright © 2016 Maddox Ltd. All rights reserved.
//

#import "EncryptionBridge.h"
#import "Encryption.h"

#import "EncryptOperation.h"
#import "UploadOperation.h"

#import "DownloadOperation.h"
#import "DecryptOperation.h"

#import "ListOperation.h"
#import "DecryptMetadataOperation.h"

#import "File.h"

#import <SimpleKeychain/A0SimpleKeychain.h>

@import UIKit;

@interface EncryptionBridge ()

@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic, strong) Encryption *encryption;
@property (nonatomic, strong) A0SimpleKeychain *keychain;

@end

@implementation EncryptionBridge

- (instancetype)initWithPassphraseCallback:(NSString * (^)())passphraseCallback
{
	if (self = [super init]){
		NSError *error = nil;
		
		self.keychain = [A0SimpleKeychain keychain];
		
		[self.keychain setUseAccessControl:YES];
		[self.keychain setDefaultAccessiblity:A0SimpleKeychainItemAccessibleWhenPasscodeSetThisDeviceOnly];
		NSString *privateKey = [self.keychain stringForKey:@"PrivateKey" promptMessage:@"Access your private key"];
		NSString *passphrase = nil;
		
		if (privateKey == nil || [privateKey length] == 0){
			if (passphraseCallback){
				passphrase = passphraseCallback();
				[self.keychain setString:passphrase forKey:@"Passphrase"];
			}
		} else {
			passphrase = [self.keychain stringForKey:@"Passphrase" promptMessage:@"Passphrase"];
		}
		
		// TODO: Private key needs to be stored securely
		NSString *createdPrivateKey = nil;
		self.encryption = [[Encryption alloc] initWithPrivateKey:privateKey passphrase:passphrase error:&error createdPrivateKey:&createdPrivateKey];
		
		if (createdPrivateKey){
			[self.keychain setString:createdPrivateKey forKey:@"PrivateKey"];
		}
		
		if (error){
			NSLog(@"Error setting up encryption: %@", error);
		}
		self.queue = [[NSOperationQueue alloc] init];
	}
	return self;
}

- (void)encryptAndUploadFile:(NSURL *)fileURL encryptionCompleteHandler:(void (^)())encryptionComplete completion:(void (^)(NSString *remotePath, NSError *error))completion
{
	EncryptOperation *encryptOperation = [[EncryptOperation alloc] init];
	encryptOperation.encryption = self.encryption;
	encryptOperation.fileURL = fileURL;
	
	UploadOperation *uploadOperation = [[UploadOperation alloc] init];
	[uploadOperation addDependency:encryptOperation];
	
	UploadOperation *metadataUploadOperation = [[UploadOperation alloc] init];
	[metadataUploadOperation addDependency:encryptOperation];
	
	__weak typeof(encryptOperation) weakEncryptOperation = encryptOperation;
	__weak typeof(uploadOperation) weakUploadOperation = uploadOperation;
	__weak typeof(metadataUploadOperation) weakMetadataUploadOperation = metadataUploadOperation;
	[encryptOperation setOperationCompleteBlock:^{
		__strong typeof(weakEncryptOperation) strongEncryptOperation = weakEncryptOperation;
		__strong typeof(weakUploadOperation) strongUploadOperation = weakUploadOperation;
		__strong typeof(weakMetadataUploadOperation) strongMetadataUploadOperation = weakMetadataUploadOperation;
		
		strongUploadOperation.fileURL = strongEncryptOperation.encryptedFileURL;
		strongMetadataUploadOperation.fileURL = strongEncryptOperation.encryptedMetadataURL;
		
		if (encryptionComplete){
			encryptionComplete();
		}
	}];
	
	[uploadOperation setOperationCompleteBlock:^{
		__strong typeof(weakUploadOperation) strongUploadOperation = weakUploadOperation;
		completion(strongUploadOperation.key, strongUploadOperation.error);
	}];
	
	[self.queue addOperation:encryptOperation];
	[self.queue addOperation:uploadOperation];
	[self.queue addOperation:metadataUploadOperation];
}

- (void)downloadAndDecryptFileAtPath:(NSString *)path downloadCompleteHandler:(void (^)())downloadComplete completion:(void (^)(NSURL *fileURL, NSError *error))completion
{
	DownloadOperation *downloadOperation = [[DownloadOperation alloc] init];
	downloadOperation.remotePath = path;
	
	DecryptOperation *decryptOperation = [[DecryptOperation alloc] init];
	decryptOperation.encryption = self.encryption;
	[decryptOperation addDependency:downloadOperation];
	
	__weak typeof(downloadOperation) weakDownloadOperation = downloadOperation;
	__weak typeof(decryptOperation) weakDecryptOperation = decryptOperation;
	[downloadOperation setOperationCompleteBlock:^{
		__strong typeof(weakDownloadOperation) strongDownloadOperation = weakDownloadOperation;
		__strong typeof(weakDecryptOperation) strongDecryptOperation = weakDecryptOperation;
		
		strongDecryptOperation.fileURL = strongDownloadOperation.fileURL;
		
		if (downloadComplete){
			downloadComplete();
		}
	}];
	
	[decryptOperation setOperationCompleteBlock:^{
		__strong typeof(weakDecryptOperation) strongDecryptOperation = weakDecryptOperation;
		completion(strongDecryptOperation.decryptedFileURL, nil);
	}];
	
	[self.queue addOperation:downloadOperation];
	[self.queue addOperation:decryptOperation];
}

- (void)downloadAndDecryptFile:(File *)file downloadCompleteHandler:(void (^)())downloadComplete completion:(void (^)(NSURL *fileURL, NSError *error))completion
{
	return [self downloadAndDecryptFileAtPath:file.key downloadCompleteHandler:downloadComplete completion:completion];
}

- (void)downloadAndDecryptMetadataFileAtPath:(NSString *)path completion:(void (^)(File *file, NSError *error))completion
{
	DownloadOperation *downloadOperation = [[DownloadOperation alloc] init];
	downloadOperation.remotePath = path;
	
	DecryptMetadataOperation *decryptOperation = [[DecryptMetadataOperation alloc] init];
	decryptOperation.encryption = self.encryption;
	[decryptOperation addDependency:downloadOperation];
	
	__weak typeof(downloadOperation) weakDownloadOperation = downloadOperation;
	__weak typeof(decryptOperation) weakDecryptOperation = decryptOperation;
	[downloadOperation setOperationCompleteBlock:^{
		__strong typeof(weakDownloadOperation) strongDownloadOperation = weakDownloadOperation;
		__strong typeof(weakDecryptOperation) strongDecryptOperation = weakDecryptOperation;
		
		strongDecryptOperation.fileURL = strongDownloadOperation.fileURL;
	}];
	
	[decryptOperation setOperationCompleteBlock:^{
		__strong typeof(weakDecryptOperation) strongDecryptOperation = weakDecryptOperation;
		
		if (strongDecryptOperation.filename){
			File *file = [[File alloc] init];
			file.filename = strongDecryptOperation.filename;
			file.key = [[path lastPathComponent] stringByReplacingOccurrencesOfString:@"." withString:@""];
			
			completion(file, nil);
		} else {
			completion(nil, nil);
		}
	}];
	
	[self.queue addOperation:downloadOperation];
	[self.queue addOperation:decryptOperation];
}

- (void)listFilesWithCompletion:(void (^)(NSArray <File *> *files, NSError *error))completion
{
	ListOperation *listOperation = [[ListOperation alloc] init];
	listOperation.encryptionBridge = self;
	
	__weak typeof(listOperation) weakListOperation = listOperation;
	[listOperation setOperationCompleteBlock:^{
		__strong typeof(weakListOperation) strongListOperation = weakListOperation;
		completion(strongListOperation.files, nil);
	}];
	
	[self.queue addOperation:listOperation];
}

@end
