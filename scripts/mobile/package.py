#!/usr/bin/env python3
"""Build mobile artifacts; optional private signing is explicitly enabled by CI."""
from pathlib import Path
import hashlib, os, shutil, subprocess, sys, tempfile, zipfile
from audit import audit_android
ROOT=Path(__file__).resolve().parents[2]
platform=sys.argv[1] if len(sys.argv)>1 else ''
if platform not in ('ios','android'):raise SystemExit('package.py ios|android')
out=ROOT/'dist/mobile'/platform;out.mkdir(parents=True,exist_ok=True)
version=subprocess.check_output([sys.executable,str(ROOT/'scripts/release.py'),'version'],text=True,cwd=ROOT).strip()
android_signed=os.environ.get('TERMPILOT_ANDROID_SIGN')=='1'
ios_signed=os.environ.get('TERMPILOT_IOS_SIGN')=='1'
targets=['aarch64-apple-ios','aarch64-apple-ios-sim'] if platform=='ios' else ['aarch64-linux-android','x86_64-linux-android']
subprocess.run([sys.executable,str(ROOT/'scripts/package-licenses.py'),str(out/'Licenses'),*targets],cwd=ROOT,check=True)
subprocess.run([sys.executable,str(ROOT/'scripts/package-source.py'),str(out/f'TermPilot-{version}-CorrespondingSource.tar.gz')],cwd=ROOT,check=True)
for name in ['LICENSE','NOTICE.md']:shutil.copy2(ROOT/name,out/name)
if platform=='android':
 subprocess.run(['bash',str(ROOT/'apps/android/gradlew'),'--no-daemon','-p',str(ROOT/'apps/android'),'exportMobileDependencyInventory'],cwd=ROOT,check=True)
 inventory=ROOT/'apps/android/app/build/mobile-licenses/maven-dependencies.txt'
 notice=out/'Licenses/Android';notice.mkdir(parents=True,exist_ok=True)
 shutil.copy2(inventory,notice/inventory.name)
 shutil.copy2(ROOT/'vendor/ironrdp-client/LICENSE-APACHE',notice/'LICENSE-APACHE-2.0')
 (notice/'NOTICE.txt').write_text('AndroidX, Kotlin, kotlinx and their Android runtime dependencies are redistributed under their upstream licenses. Exact coordinates are listed in maven-dependencies.txt. Apache-2.0 applies to AndroidX, Kotlin and kotlinx. Additional licenses below are copied from dependency archives.\n')
 # Preserve embedded dependency notices, without shipping absolute cache paths.
 import re
 coordinates=inventory.read_text().splitlines()
 cache=Path(os.environ.get('GRADLE_USER_HOME',Path.home()/'.gradle'))/'caches/modules-2/files-2.1'
 for coordinate in coordinates:
  group,name,dependency_version=coordinate.split(':')
  for archive in (cache/group/name/dependency_version).glob('*/*'):
   if archive.suffix not in ('.jar','.aar'):continue
   with zipfile.ZipFile(archive) as z:
    for entry in z.namelist():
     if re.search(r'(^|/)(LICENSE|NOTICE|COPYING)([./_-]|$)',entry,re.I):
      data=z.read(entry)
      if len(data)>1024*1024:raise SystemExit('Unexpected notice size')
      target=notice/(group+'.'+name+'-'+dependency_version)/Path(entry).name
      target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
 sdk=Path(os.environ.get('ANDROID_HOME',ROOT/'.tools/mobile/android-sdk'))
 zipalign=sdk/'build-tools/36.0.0/zipalign'
 for abi in ['arm64-v8a','x86_64']:
  subprocess.run(['bash',str(ROOT/'apps/android/gradlew'),'--no-daemon','-p',str(ROOT/'apps/android'),'assembleInternalRelease','-PtermpilotAbi='+abi],cwd=ROOT,check=True)
  source=ROOT/'apps/android/app/build/outputs/apk/internalRelease/app-internalRelease.apk'
  label='signed' if android_signed else 'test'
  dest=out/f'TermPilot-{version}-Android-{abi}-{label}.apk';shutil.copy2(source,dest)
  badging=subprocess.check_output([str(sdk/'build-tools/36.0.0/aapt'),'dump','badging',str(dest)],text=True)
  assert "versionName='"+version+"'" in badging,'APK version mismatch'
  subprocess.run([str(zipalign),'-c','-P','16','-v','4',str(dest)],check=True,stdout=subprocess.DEVNULL)
  subprocess.run([str(sdk/'build-tools/36.0.0/apksigner'),'verify',str(dest)],check=True)
  audit_android(dest, abi)
  subprocess.run([sys.executable,str(ROOT/'scripts/audit-privacy.py'),str(dest)],check=True)
 signing_note='Uses the configured persistent Android signing key. Updates require the same key and a non-decreasing versionCode.' if android_signed else 'Uses a local/CI debug key. Fresh CI runs may use different keys and cannot always upgrade an existing installation. Back up data before changing signing identities.'
 (out/'INSTALL.txt').write_text('TermPilot Android\nInstall the matching APK. '+signing_note+'\nNo Node.js/Python runtime is bundled. Android 11+; ARM64 hardware, x86_64 testing.\n',encoding='utf-8')
else:
 for sdk,label in [('iphoneos','unsigned-device'),('iphonesimulator','simulator-arm64')]:
  app=ROOT/'apps/ios/.derived/Build/Products'/('Release-'+sdk)/'TermPilot.app'
  if not app.exists():raise SystemExit('Build '+sdk+' first')
  with tempfile.TemporaryDirectory(prefix='TermPilot-app-',dir=out) as staged:
   clean=Path(staged)/'TermPilot.app';shutil.copytree(app,clean,symlinks=True)
   shutil.rmtree(clean/'PlugIns',ignore_errors=True) # XCTest bundles are not app features.
   if sdk=='iphoneos':
    # This artifact is deliberately unsigned; provisioning/identity belongs to
    # a separate, private signing step. Preserve the installed app's identity.
    for profile in clean.rglob('embedded.mobileprovision'):profile.unlink()
    for signature in clean.rglob('_CodeSignature'):shutil.rmtree(signature)
   # Remove linker OSO paths from device AND simulator binaries before signing.
   for binary in [p for p in clean.rglob('*') if p.is_file() and not p.is_symlink()]:
    with binary.open('rb') as stream:magic=stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe'):continue
    if sdk=='iphoneos':
     subprocess.run(['codesign','--remove-signature',str(binary)],check=True)
    subprocess.run(['xcrun','strip','-S',str(binary)],check=True)
   if sdk=='iphonesimulator':subprocess.run(['codesign','--force','--sign','-',str(clean)],check=True)
   subprocess.run([sys.executable,str(ROOT/'scripts/audit-privacy.py'),str(clean)],check=True)
   subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(clean),str(out/f'TermPilot-{version}-iOS-{label}.zip')],check=True)
   if sdk=='iphoneos' and ios_signed:
    subprocess.run([sys.executable,str(ROOT/'scripts/mobile/sign-ios.py'),str(clean),str(out/f'TermPilot-{version}-iOS-iPadOS-signed.ipa')],check=True)
 with tempfile.TemporaryDirectory(prefix='TermPilot-framework-',dir=out) as temporary:
  framework=Path(temporary)/'TermPilotMobile.xcframework'
  args=['xcodebuild','-create-xcframework']
  for target in targets:args+=['-library',str(ROOT/'target'/target/'release/libtermpilot_mobile.a'),'-headers',str(ROOT/'bindings/mobile')]
  subprocess.run(args+['-output',str(framework)],check=True)
  # Preserve Rust LTO members and the static SDK symbol index. This developer
  # SDK also contains debug metadata from the precompiled Rust standard library;
  # it is not installed in the app. App binaries are stripped/audited above.
  subprocess.run(['ditto','-c','-k','--keepParent',str(framework),str(out/f'TermPilot-{version}-Mobile.xcframework.zip')],check=True)
 signing_note='The signed IPA is installable only on devices allowed by its provisioning profile. It contains the required public signing identity/profile, never the private key.' if ios_signed else 'No installable IPA is included. Configure CI signing secrets or open apps/ios/TermPilot.xcodeproj and sign for your own devices.'
 (out/'INSTALL.txt').write_text('TermPilot iPhone/iPad\nThe simulator ZIP can be installed with xcrun simctl install. The device ZIP is UNSIGNED. '+signing_note+'\niOS/iPadOS 17+; background continued tasks require iOS 26+ and hardware validation.\n',encoding='utf-8')
subprocess.run([sys.executable,str(ROOT/'scripts/audit-privacy.py'),str(out/'Licenses')],check=True)
files=sorted(p for p in out.iterdir() if p.is_file() and p.name!='SHA256SUMS')
for artifact in files:
 if artifact.name.endswith('-Mobile.xcframework.zip'):continue
 if artifact.suffix in ('.zip','.apk','.ipa') or artifact.name.endswith('.tar.gz'):
  options=['--allow-development-signing'] if artifact.suffix=='.ipa' and ios_signed else []
  subprocess.run([sys.executable,str(ROOT/'scripts/audit-privacy.py'),str(artifact),*options],check=True)
with (out/'SHA256SUMS').open('w') as f:
 for p in files:
  h=hashlib.file_digest(p.open('rb'),'sha256').hexdigest();f.write(h+'  '+p.name+'\n')
print(out)
