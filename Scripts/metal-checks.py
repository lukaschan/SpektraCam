#!/usr/bin/env python3
import os,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[1];out=pathlib.Path('/private/tmp/spektrafilm-build')
xcode=pathlib.Path('/Applications/Xcode.app/Contents/Developer');env=os.environ.copy();env['DEVELOPER_DIR']=str(xcode)
args=[str(xcode/'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'),'-sdk',str(xcode/'Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk'),'-module-cache-path',str(out/'SymbolModuleCache'),str(root/'SpektraCam/Rendering/Metal/MetalDispatch.swift'),str(root/'SpektraCam/Rendering/Metal/MetalStages.swift'),str(root/'Scripts/metal-checks.swift'),'-o',str(out/'metal-checks')]
subprocess.run(args,env=env,check=True)
subprocess.run([str(out/'metal-checks'),str(root)],env=env,check=True)
