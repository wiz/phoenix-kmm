import Foundation
import Combine
import CommonCrypto
import CryptoKit
import LocalAuthentication
import os.log

#if DEBUG && false
fileprivate var log = Logger(
	subsystem: Bundle.main.bundleIdentifier!,
	category: "AppSecurity"
)
#else
fileprivate var log = Logger(OSLog.disabled)
#endif

/// Represents the availability of Biometrics on the current device.
/// Devices either support TouchID or FaceID,
/// but the user needs to have enabled and enrolled in the service.
///
enum BiometricSupport {
	
	case touchID_available
	case touchID_notAvailable
	case touchID_notEnrolled
	
	case faceID_available
	case faceID_notAvailable
	case faceID_notEnrolled
	
	case notAvailable
	
	func isAvailable() -> Bool {
		return (self == .touchID_available) || (self == .faceID_available)
	}
}

// Names of entries stored within the OS keychain:
private let keychain_accountName_keychain = "securityFile_keychain"
private let keychain_accountName_biometrics = "securityFile_biometrics"
private let keychain_accountName_softBiometrics = "biometrics"

class AppSecurity {
	
	/// Singleton instance
	///
	public static let shared = AppSecurity()
	
	/// Changes always posted to the main thread.
	///
	public let enabledSecurity = CurrentValueSubject<EnabledSecurity, Never>(EnabledSecurity())
	
	/// Serial queue ensures that only one operation is reading/modifying the
	/// keychain and/or security file at any given time.
	///
	private let queue = DispatchQueue(label: "AppSecurity")
	
	private init() {/* must use shared instance */}
	
	// --------------------------------------------------------------------------------
	// MARK:- Private Utilities
	// --------------------------------------------------------------------------------
	
	private lazy var securityJsonUrl: URL = {
		
		// Thread safety: lazy => thread-safe / uses dispatch_once primitives internally
		
		guard let appSupportDir = try?
			FileManager.default.url(for: .applicationSupportDirectory,
			                         in: .userDomainMask,
			             appropriateFor: nil,
			                     create: true)
		else {
			fatalError("FileManager returned nil applicationSupportDirectory !")
		}
		
		return appSupportDir.appendingPathComponent("security.json", isDirectory: false)
	}()
	
	/// Performs disk IO - prefer use in background thread.
	///
	private func readFromDisk() -> SecurityFile {
		
		var result: SecurityFile? = nil
		do {
			let data = try Data(contentsOf: self.securityJsonUrl)
			result = try JSONDecoder().decode(SecurityFile.self, from: data)
		} catch {
			// NB: in the event of various failures, we rely on the `createBackup` system.
		}
		
		return result ?? SecurityFile()
	}
	
	/// Performs disk IO - prefer use in background thread.
	///
	private func writeToDisk(securityFile: SecurityFile) throws {
		
		var url = self.securityJsonUrl
		
		let jsonData = try JSONEncoder().encode(securityFile)
		try jsonData.write(to: url, options: [.atomic])
		
		do {
			var resourceValues = URLResourceValues()
			resourceValues.isExcludedFromBackup = true
			try url.setResourceValues(resourceValues)
			
		} catch {
			// Don't throw from this error as it's an optimization
			log.error("Error excluding \(url.lastPathComponent) from backup \(String(describing: error))")
		}
	}
	
	private func validateParameter(mnemonics: [String]) -> Data {
		
		precondition(mnemonics.count == 12, "Invalid parameter: mnemonics.count")
		
		let space = " "
		precondition(mnemonics.allSatisfy { !$0.contains(space) },
		  "Invalid parameter: mnemonics.word")
		
		let mnemonicsData = mnemonics.joined(separator: space).data(using: .utf8)
		
		precondition(mnemonicsData != nil,
		  "Invalid parameter: mnemonics.work contains non-utf8 characters")
		
		return mnemonicsData!
	}
	
	private func calculateEnabledSecurity(_ securityFile: SecurityFile) -> EnabledSecurity {
		
		var enabledSecurity = EnabledSecurity.none
		
		if securityFile.biometrics != nil {
			enabledSecurity.insert(.biometrics)
			enabledSecurity.insert(.advancedSecurity)
		} else if (securityFile.keychain != nil) && self.getSoftBiometricsEnabled() {
			enabledSecurity.insert(.biometrics)
		}
		
		if (securityFile.passphrase != nil) {
			enabledSecurity.insert(.passphrase)
		}
		
		return enabledSecurity
	}
	
	// --------------------------------------------------------------------------------
	// MARK:- Public Utilities
	// --------------------------------------------------------------------------------
	
	public func generateEntropy() -> Data {
		
		let key = SymmetricKey(size: .bits128)
		
		return key.withUnsafeBytes {(bytes: UnsafeRawBufferPointer) -> Data in
			return Data(bytes: bytes.baseAddress!, count: bytes.count)
		}
	}
	
	/// Returns the device's current status concerning biometric support.
	///
	public func deviceBiometricSupport() -> BiometricSupport {
		
		let context = LAContext()
		
		var error : NSError?
		let result = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
		
		if context.biometryType == .touchID {
			if result && (error == nil) {
				return .touchID_available
			} else {
				if let error = error as? LAError, error.code == .biometryNotEnrolled {
					return .touchID_notEnrolled
				} else {
					return .touchID_notAvailable
				}
			}
		}
		if context.biometryType == .faceID {
			if result && (error == nil) {
				return .faceID_available
			} else {
				if let error = error as? LAError, error.code == .biometryNotEnrolled {
					return .faceID_notEnrolled
				} else {
					return .faceID_notAvailable
				}
			}
		}
		
		return .notAvailable
	}
	
	public func performMigration(previousBuild: String) -> Void {
		log.trace("performMigration(previousBuild: \(previousBuild)")
		
		if previousBuild.isVersion(lessThan: "5") {
			
			let keychain = GenericPasswordStore()
			var hardBiometricsEnabled = false
			
			do {
				hardBiometricsEnabled = try keychain.keyExists(account: keychain_accountName_biometrics)
			} catch {
				log.error("keychain.keyExists(account: hardBiometrics): error: \(String(describing: error))")
			}
			
			if hardBiometricsEnabled {
				// Then soft biometrics are implicitly enabled.
				// So we need to set that flag.
				
				let account = keychain_accountName_softBiometrics
				do {
					try keychain.deleteKey(account: account)
				} catch {
					log.error("keychain.deleteKey(account: softBiometrics): error: \(String(describing: error))")
				}
				
				do {
					var query = [String: Any]()
					query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
					
					try keychain.storeKey("true", account: account, mixins: query)
					
				} catch {
					log.error("keychain.storeKey(account: softBiometrics): error: \(String(describing: error))")
				}
			}
		}
	}
	
	// --------------------------------------------------------------------------------
	// MARK:- Keychain
	// --------------------------------------------------------------------------------
	
	/// Attempts to extract the mnemonics using the keychain.
	/// If the user hasn't enabled any additional security options, this will succeed.
	/// Otherwise it will fail, and the completion closure will specify the additional security in place.
	///
	public func tryUnlockWithKeychain(
		completion: @escaping (_ mnemonics: [String]?, _ configuration: EnabledSecurity) -> Void
	) {
		
		let finish = {(_ mnemonics: [String]?, _ configuration: EnabledSecurity) -> Void in
			DispatchQueue.main.async {
				self.enabledSecurity.send(configuration)
				completion(mnemonics, configuration)
			}
		}
		
		// Disk IO ahead - get off the main thread.
		// Also - go thru the serial queue for proper thread safety.
		queue.async {
			
			// Fetch the "security.json" file.
			// If the file doesn't exist, an empty SecurityFile is returned.
			let securityFile = self.readFromDisk()
			
			let result = self.readKeychainEntry(securityFile)
			let enabledSecurity = self.calculateEnabledSecurity(securityFile)
			
			let mnemonics = try? result.get()
			finish(mnemonics, enabledSecurity)
		}
	}
	
	private func readKeychainEntry(_ securityFile: SecurityFile) -> Result<[String], Error> {
		
		// The securityFile tells us which security options have been enabled.
		// If there isn't a keychain entry, then we cannot unlock the seed.
		guard
			let keyInfo = securityFile.keychain as? KeyInfo_ChaChaPoly,
			let sealedBox = try? keyInfo.toSealedBox()
		else {
			return .failure(genericError(401, "SecurityFile doesn't have keychain entry"))
		}
		
		let keychain = GenericPasswordStore()
		
		// Read the lockingKey from the OS keychain
		let fetchedKey: SymmetricKey?
		do {
			fetchedKey = try keychain.readKey(account: keychain_accountName_keychain)
		} catch {
			log.error("keychain.readKey(account: keychain): error: \(String(describing: error))")
			return .failure(error)
		}
		
		guard let lockingKey = fetchedKey else {
			return .failure(genericError(401, "Keychain entry missing"))
		}
		
		// Decrypt the databaseKey using the lockingKey
		let mnemonicsData: Data
		do {
			mnemonicsData = try ChaChaPoly.open(sealedBox, using: lockingKey)
		} catch {
			return .failure(error)
		}
		
		guard let mnemonicsString = String(data: mnemonicsData, encoding: .utf8) else {
			return .failure(genericError(500, "Keychain data is invalid"))
		}
		
		let mnemonics = mnemonicsString.split(separator: " ").map { String($0) }
		return .success(mnemonics)
	}
	
	/// Updates the keychain & security file to include an keychain entry.
	/// This is a destructive action - existing entries will be removed from
	/// both the keychain & security file.
	///
	/// It is designed to be called either:
	/// - we need to bootstrap the system on first launch
	/// - the user is explicitly disabling existing security options
	///
	public func addKeychainEntry(
		mnemonics : [String],
		completion  : @escaping (_ error: Error?) -> Void
	) {
		let mnemonicsData = validateParameter(mnemonics: mnemonics)
		
		let succeed = {(securityFile: SecurityFile) -> Void in
			DispatchQueue.main.async {
				let newEnabledSecurity = self.calculateEnabledSecurity(securityFile)
				self.enabledSecurity.send(newEnabledSecurity)
				completion(nil)
			}
		}
		
		let fail = {(_ error: Error) -> Void in
			DispatchQueue.main.async {
				completion(error)
			}
		}
		
		// Disk IO ahead - get off the main thread.
		// Also - go thru the serial queue for proper thread safety.
		queue.async {
			
			let lockingKey = SymmetricKey(size: .bits256)
			
			let sealedBox: ChaChaPoly.SealedBox
			do {
				sealedBox = try ChaChaPoly.seal(mnemonicsData, using: lockingKey)
			} catch {
				return fail(error)
			}
			
			let keyInfo = KeyInfo_ChaChaPoly(sealedBox: sealedBox)
			let securityFile = SecurityFile(keychain: keyInfo)
			
			// Order matters !
			// Don't lock out the user from their wallet !
			//
			// There are 3 scenarios in which this method may be called:
			//
			// 1. App was launched for the first time.
			//    There are no entries in the keychain.
			//    The security.json file doesn't exist.
			//
			// 2. User has existing security options, but is choosing to disable them.
			//    The given databaseKey corresponds to the existing database file.
			//    There are existing entries in the keychain.
			//    The security.json file exists, and contains entries.
			//
			// 3. Something bad happened during app launch.
			//    We discovered a corrupt database, a corrupt security.json,
			//    or necessary keychain entries have gone missing.
			//    When this occurs, the system invokes the various `backup` functions.
			//    This creates a copy of the database, security.json file & keychain entries.
			//    Afterwards this function is called.
			//    And we can treat this scenario as the equivalent of a first app launch.
			//
			// So situation #2 is the dangerous one.
			// Consider what happens if:
			//
			// - we delete the touchID entry from the database
			// - then the app crashes
			//
			// Answer => we just lost the user's data ! :(
			//
			// So we're careful to to perform operations in a particular order here:
			//
			// - add new entry to OS keychain
			// - write security.json file to disk
			// - then we can safely remove the old entries from the OS keychain
			
			let keychain = GenericPasswordStore()
			
			do {
				try keychain.deleteKey(account: keychain_accountName_keychain)
			} catch {/* ignored */}
			do {
				// Access control considerations:
				//
				// This is only for fetching the databaseKey,
				// which we only need to do once when launching the app.
				// So we shouldn't need access to the keychain item when the device is locked.
				
				var query = [String: Any]()
				query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
				
				try keychain.storeKey( lockingKey,
				              account: keychain_accountName_keychain,
				               mixins: query)
			} catch {
				log.error("keychain.storeKey(account: keychain): error: \(String(describing: error))")
				return fail(error)
			}
			
			do {
				try self.writeToDisk(securityFile: securityFile)
			} catch {
				log.error("writeToDisk(securityFile): error: \(String(describing: error))")
				return fail(error)
			}
			
			// Now we can safely delete the touchID entry in the database (if it exists)
			do {
				try keychain.deleteKey(account: keychain_accountName_biometrics)
			} catch {/* ignored */}
			
			succeed(securityFile)
			
		} // </queue.async>
	}
	
	public func setSoftBiometrics(
		enabled    : Bool,
		completion : @escaping (_ error: Error?) -> Void
	) -> Void {
		
		let succeed = {
			let securityFile = self.readFromDisk()
			DispatchQueue.main.async {
				let newEnabledSecurity = self.calculateEnabledSecurity(securityFile)
				self.enabledSecurity.send(newEnabledSecurity)
				completion(nil)
			}
		}
		
		let fail = {(_ error: Error) -> Void in
			DispatchQueue.main.async {
				completion(error)
			}
		}
		
		// Disk IO ahead - get off the main thread.
		// Also - go thru the serial queue for proper thread safety.
		queue.async {
			
			let keychain = GenericPasswordStore()
			let account = keychain_accountName_softBiometrics
			
			if enabled {
				do {
					var query = [String: Any]()
					query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
					
					try keychain.storeKey("true", account: account, mixins: query)
					
				} catch {
					log.error("keychain.storeKey(account: softBiometrics): error: \(String(describing: error))")
					return fail(error)
				}
				
			} else {
				do {
					try keychain.deleteKey(account: account)
				
				} catch {
					log.error("keychain.deleteKey(account: softBiometrics): error: \(String(describing: error))")
					return fail(error)
				}
			}
			
			succeed()
		
		} // </queue.async>
	}
	
	public func getSoftBiometricsEnabled() -> Bool {
		
		let keychain = GenericPasswordStore()
		let account = keychain_accountName_softBiometrics
		
		var enabled = false
		do {
			let value: String? = try keychain.readKey(account: account)
			enabled = value != nil
			
		} catch {
			log.error("keychain.readKey(account: softBiometrics): error: \(String(describing: error))")
		}
		
		return enabled
	}
	
	// --------------------------------------------------------------------------------
	// MARK:- Biometrics
	// --------------------------------------------------------------------------------
	
	private func biometricsPrompt() -> String {
		
		return NSLocalizedString( "App is locked",
		                 comment: "Biometrics prompt to unlock the Phoenix app"
		)
	}
	
	/// Attempts to extract the seed using biometrics (e.g. touchID, faceID)
	///
	public func tryUnlockWithBiometrics(
		prompt: String? = nil,
		completion: @escaping (_ result: Result<[String], Error>) -> Void
	) {
		let succeed = {(_ mnemonics: [String]) in
			DispatchQueue.main.async {
				completion(Result.success(mnemonics))
			}
		}
		
		let fail = {(_ error: Error) -> Void in
			DispatchQueue.main.async {
				completion(Result.failure(error))
			}
		}
		
		let trySoftBiometrics = {(_ securityFile: SecurityFile) -> Void in
			
			let result = self.readKeychainEntry(securityFile)
			switch result {
			case .failure(let error):
				fail(error)
			
			case .success(let mnemonics):
				self.tryGenericBiometrics { (success, error) in
					if success {
						succeed(mnemonics)
					} else {
						fail(error ?? genericError(401, "Biometrics prompt failed / cancelled"))
					}
				}
			}
		}
		
		// Disk IO ahead - get off the main thread.
		// Also - go thru the serial queue for proper thread safety.
		queue.async {
			
			// Fetch the "security.json" file.
			// If the file doesn't exist, an empty SecurityFile is returned.
			let securityFile = self.readFromDisk()
			
			// The file tells us which security options have been enabled.
			// If there isn't a keychain entry, then we cannot unlock the seed.
			guard
				let keyInfo_biometrics = securityFile.biometrics as? KeyInfo_ChaChaPoly,
				let sealedBox_biometrics = try? keyInfo_biometrics.toSealedBox()
			else {
				
				if self.getSoftBiometricsEnabled() {
					return trySoftBiometrics(securityFile)
				} else {
					return fail(genericError(400, "SecurityFile doesn't have biometrics entry"))
				}
			}
			
			let context = LAContext()
			context.localizedReason = prompt ?? self.biometricsPrompt()
			
			var query = [String: Any]()
			query[kSecUseAuthenticationContext as String] = context
			
			let keychain = GenericPasswordStore()
			let account = keychain_accountName_biometrics
		
			let fetchedKey: SymmetricKey?
			do {
				fetchedKey = try keychain.readKey(account: account, mixins: query)
			} catch {
				return fail(error)
			}
			
			guard let lockingKey = fetchedKey else {
				return fail(genericError(401, "Biometrics keychain entry missing"))
			}
		
			// Decrypt the databaseKey using the lockingKey
			let mnemonicsData: Data
			do {
				mnemonicsData = try ChaChaPoly.open(sealedBox_biometrics, using: lockingKey)
			} catch {
				return fail(error)
			}
			
			guard let mnemonicsString = String(data: mnemonicsData, encoding: .utf8) else {
				return fail(genericError(500, "Keychain data is invalid"))
			}
			let mnemonics = mnemonicsString.split(separator: " ").map { String($0) }
			
		#if targetEnvironment(simulator)
			
			// On the iOS simulator you can fake Touch ID.
			//
			// Features -> Touch ID -> Enroll
			//                      -> Matching touch
			//                      -> Non-matching touch
			//
			// However, it has some shortcomings.
			//
			// On the device:
			//     Attempting to read the entry from the keychain will prompt
			//     the user to authenticate with Touch ID. And the keychain
			//     entry is only returned if Touch ID succeeds.
			//
			// On the simulator:
			//     Attempting to read the entry from the keychain always succceeds.
			//     It does NOT prompt the user for Touch ID,
			//     giving the appearance that we didn't code something properly.
			//     But in reality, this is just a bug in the iOS simulator.
			//
			// So we're going to fake it here.
			
			self.tryGenericBiometrics {(success, error) in
			
				if let error = error {
					fail(error)
				} else {
					succeed(mnemonics)
				}
			}
		#else
		
			// iOS device
			succeed(mnemonics)
		
		#endif
		}
	}
	
	private func tryGenericBiometrics(
		prompt     : String? = nil,
		completion : @escaping (Bool, Error?) -> Void
	) -> Void {
		
		let context = LAContext()
		context.evaluatePolicy( .deviceOwnerAuthenticationWithBiometrics,
		       localizedReason: prompt ?? self.biometricsPrompt(),
		                 reply: completion)
	}
	
	public func addBiometricsEntry(
		mnemonics : [String],
		completion  : @escaping (_ error: Error?) -> Void
	) {
		let mnemonicsData = validateParameter(mnemonics: mnemonics)
		
		let succeed = {(securityFile: SecurityFile) -> Void in
			DispatchQueue.main.async {
				let newEnabledSecurity = self.calculateEnabledSecurity(securityFile)
				self.enabledSecurity.send(newEnabledSecurity)
				completion(nil)
			}
		}
		
		let fail = {(_ error: Error) -> Void in
			DispatchQueue.main.async {
				completion(error)
			}
		}
		
		// Disk IO ahead - get off the main thread.
		// Also - go thru the serial queue for proper thread safety.
		queue.async {
			
			let lockingKey = SymmetricKey(size: .bits256)
			
			let sealedBox: ChaChaPoly.SealedBox
			do {
				sealedBox = try ChaChaPoly.seal(mnemonicsData, using: lockingKey)
			} catch {
				return fail(error)
			}
			
			let keyInfo_touchID = KeyInfo_ChaChaPoly(sealedBox: sealedBox)
			
			let oldSecurityFile = self.readFromDisk()
			let securityFile = SecurityFile(
				touchID    : keyInfo_touchID,
				passphrase : oldSecurityFile.passphrase // maintain existing option
			)
			
			// Order matters !
			// Don't lock out the user from their wallet !
			//
			// There are 2 scenarios in which this method may be called:
			//
			// 1. User had no security options enabled, but is now enabling touch ID.
			//    There is an existing keychain entry for the keychain option.
			//    There is an existing security.json file with the keychain option.
			//
			// 2. User only had passphrase option enabled, but is now adding touch ID.
			//    There is an existing keychain entry for the passphrase option.
			//    There is an existing security.json file with the passphrase option.
			
			let keychain = GenericPasswordStore()
			
			do {
				try keychain.deleteKey(account: keychain_accountName_biometrics)
			} catch {/* ignored */}
			do {
				let accessControl = SecAccessControlCreateWithFlags(
					/* allocator  : */ nil,
					/* protection : */ kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
					/* flags      : */ .userPresence,
					/* error      : */ nil
				)!
				
				var query = [String: Any]()
				query[kSecAttrAccessControl as String] = accessControl
				
				try keychain.storeKey(lockingKey,
				             account: keychain_accountName_biometrics,
				              mixins: query)
			} catch {
				print("keychain.storeKey(account: touchID): error: \(error)")
				return fail(error)
			}
			
			do {
				try self.writeToDisk(securityFile: securityFile)
			} catch {
				print("writeToDisk(securityFile): error: \(error)")
				return fail(error)
			}
			
			// Now we can safely delete the keychain entry now (if it exists)
			do {
				try keychain.deleteKey(account: keychain_accountName_keychain)
			} catch {/* ignored */}
			
			succeed(securityFile)
		}
	}
}

// MARK:- Utilities

fileprivate func genericError(_ code: Int, _ description: String? = nil) -> NSError {
	
	var userInfo = [String: String]()
	if let description = description {
		userInfo[NSLocalizedDescriptionKey] = description
	}
		
	return NSError(domain: "AppSecurity", code: code, userInfo: userInfo)
}
