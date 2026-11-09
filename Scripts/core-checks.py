#!/usr/bin/env python3
"""Compile targeted native checks without creating a second Xcode project."""
import argparse,json,os,pathlib,platform,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path('/private/tmp/spektrafilm-build');out.mkdir(exist_ok=True)
xcode=pathlib.Path('/Applications/Xcode.app/Contents/Developer')
env=os.environ.copy();env['DEVELOPER_DIR']=str(xcode)
sources = {p.stem: p for p in (root/'SpektraCam').rglob('*.swift')}
assert len(sources) == len(list((root/'SpektraCam').rglob('*.swift'))), 'Duplicate Swift file names'
checks={
 'color-benchmark':(['ImageGeometry','CropSelection','EditRecipe','ParameterCatalog','FilmStock','StockDefaults','SpectralCore','CouplerCore','UpsamplingCore','AppearanceCore','GamutCore','PrintExposureCore','PrintChemistryCore','MeteringCore','ModelLibrary','ExposureTableCore','ColorPipeline','MetalModelResources','MetalColorPipeline'],['.']),
 'color-pipeline':(['ImageGeometry','CropSelection','EditRecipe','ParameterCatalog','FilmStock','StockDefaults','SpectralCore','CouplerCore','UpsamplingCore','AppearanceCore','GamutCore','PrintExposureCore','PrintChemistryCore','MeteringCore','ModelLibrary','ExposureTableCore','ColorPipeline'],['.']),
 'metal-color':(['ImageGeometry','CropSelection','EditRecipe','ParameterCatalog','FilmStock','StockDefaults','SpectralCore','CouplerCore','UpsamplingCore','AppearanceCore','GamutCore','PrintExposureCore','PrintChemistryCore','MeteringCore','ModelLibrary','ExposureTableCore','ColorPipeline','MetalModelResources','MetalColorPipeline'],['.']),
 'spatial-pipeline':(['ImageGeometry','CropSelection','EditRecipe','ParameterCatalog','FilmStock','StockDefaults','SpectralCore','CouplerCore','UpsamplingCore','AppearanceCore','GamutCore','PrintExposureCore','PrintChemistryCore','MeteringCore','ModelLibrary','ExposureTableCore','ColorPipeline','StatisticsCore','SpatialCore','HalationCore','GrainCore','DiffusionCore','ReferenceCorrectionCore','RawAdjustments','FilmPipeline'],['.']),
 'metal-film':(['ImageGeometry','CropSelection','EditRecipe','ParameterCatalog','FilmStock','StockDefaults','SpectralCore','CouplerCore','UpsamplingCore','AppearanceCore','GamutCore','PrintExposureCore','PrintChemistryCore','MeteringCore','ModelLibrary','ExposureTableCore','ColorPipeline','StatisticsCore','SpatialCore','HalationCore','GrainCore','DiffusionCore','ReferenceCorrectionCore','RawAdjustments','FilmPipeline','MetalModelResources','MetalSpatial','MetalDiffusion','PhotoColorBridge','MetalFilmPipeline'],['.']),
 'spatial':(['SpectralCore','SpatialCore'],['Reference/Fixtures/spatial-stages.json']),
 'metal-spatial':(['SpectralCore','SpatialCore','MetalSpatial'],['.']),
 'metal-diffusion':(['SpectralCore','SpatialCore','DiffusionCore','MetalDiffusion'],['.']),
 'metal-grain':(['SpectralCore','SpatialCore','StatisticsCore','GrainCore','MetalGrain'],['.']),
 'halation':(['SpectralCore','SpatialCore','HalationCore'],['Reference/Fixtures/halation-stages.json']),
 'diffusion':(['SpectralCore','SpatialCore','DiffusionCore'],['Reference/Fixtures/diffusion-stages.json']),
 'filtered-exposure':(['SpectralCore','UpsamplingCore','AppearanceCore','GamutCore','ModelLibrary','ExposureTableCore'],['.']),
 'statistics':(['StatisticsCore'],[]),
 'grain':(['StatisticsCore','SpectralCore','SpatialCore','GrainCore'],['Reference/Fixtures/grain-stages.json']),
 'photo-color':(['PhotoColorBridge'],[]),
 'geometry':(['ImageGeometry','GeometryRenderer','CropSelection'],[]),
 'recipe':(['ImageGeometry','CropSelection','EditRecipe','ParameterCatalog','FilmStock','StockDefaults'],[]),
 'spectral':(['SpectralCore'],['Reference/Fixtures/core-stages.json']),
 'export':(['ImageGeometry','CropSelection','GeometryRenderer','PhotoExporter','PhotoMetadata','ImportedPhoto'],[]),
 'coupler':(['SpectralCore','CouplerCore'],['Reference/Fixtures/coupler-stages.json']),
 'upsampling':(['SpectralCore','UpsamplingCore'],['Reference/Fixtures']),
 'appearance':(['AppearanceCore'],['Reference/Fixtures/appearance-stages.json']),
 'print-exposure':(['SpectralCore','PrintExposureCore'],['Reference/Fixtures/print-exposure-stages.json']),
 'print-morph':(['SpectralCore','PrintChemistryCore'],['Reference/Fixtures/print-morph-stages.json']),
 'metering':(['SpectralCore','MeteringCore'],['Reference/Fixtures/metering-stages.json']),
 'gamut':(['SpectralCore','AppearanceCore','GamutCore'],['Reference/Fixtures']),
}
checks['histogram'] = (['PhotoHistogram'], [])
checks['geotag'] = (['CameraLocation','PhotoMetadata'], [])
checks['raw-input'] = (checks['recipe'][0] + ['PhotoColorBridge','SourceImageRenderer','PhotoMetadata','ImportedPhoto'], [])
checks['tone'] = (checks['recipe'][0] + ['ToneRenderer','RawAdjustments','PhotoColorBridge','CubeLUT'], [])
checks['lut'] = (checks['tone'][0] + ['LUTLibrary'], [])
checks['source'] = (checks['recipe'][0] + ['PhotoColorBridge','SourceImageRenderer'], [])
checks['exposure'] = (checks['color-pipeline'][0], ['.'])
checks['preview'] = (checks['metal-film'][0] + ['SourceImageRenderer','ToneRenderer','CubeLUT','PhotoExporter','GeometryRenderer','RenderMemoryBudget','FilmRenderResources','PhotoRenderer'], ['.'])
checks['processed-export'] = (checks['preview'][0] + ['PhotoMetadata','ImportedPhoto'], ['.'])
checks['bypass'] = checks['processed-export']
checks['stress-export'] = checks['processed-export']
checks['contrast'] = checks['preview']
checks['tone-response'] = checks['processed-export']
checks['scene-tone'] = checks['preview']
checks['raw-order'] = (checks['preview'][0], ['.'])
checks['library'] = (checks['processed-export'][0] + ['LibraryPhoto','LibraryFiles','LibraryImages','PhotoLibrary','LUTLibrary'], ['.'])
checks['monochrome-grain'] = (checks['metal-film'][0], ['.'])
checks['film-noise'] = (checks['metal-film'][0], ['.'])
checks['film-benchmark'] = (checks['metal-film'][0], ['.'])
checks['batch-export'] = (checks['library'][0] + ['BatchPhotoExporter','BatchExportModel','PhotoLibraryWriter'], ['.'])
checks['sdr-pipeline'] = (checks['processed-export'][0] + ['BatchPhotoExporter'], ['.'])
checks['render-cache'] = (checks['processed-export'][0], ['.'])
for key, (files, arguments) in checks.items():
 if 'PhotoSource' not in files and any(f in files for f in ['SourceImageRenderer','PhotoExporter','ImportedPhoto']):
  files.append('PhotoSource')
 if 'PreviewQuality' not in files and any(f in files for f in ['LibraryFiles','PhotoRenderer']):
  files.append('PreviewQuality')
 if 'LibraryImages' in files and 'ImageRequestPool' not in files:
  files.append('ImageRequestPool')
checks['image-requests'] = (['ImageRequestPool'], [])
checks['editor-session-benchmark'] = (list(dict.fromkeys(checks['processed-export'][0] + ['EditorSession','EditorDefaults','PhotoHistogram','LUTLibrary'])), ['.'])
checks['editor-benchmark'] = (checks['processed-export'][0], ['.'])
checks['lut-grain'] = (checks['processed-export'][0], ['.'])
parser=argparse.ArgumentParser();parser.add_argument('checks',nargs='*',choices=list(checks));parser.add_argument('--debug-benchmarks', action='store_true');parser.add_argument('--input', nargs='+', default=[]);parser.add_argument('--simulator', action='store_true');args=parser.parse_args()
sdkName = 'iphonesimulator' if args.simulator else 'macosx'
sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk',sdkName,'--show-sdk-path'],env=env,text=True).strip()
compiler=[str(xcode/'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'),'-sdk',sdk,'-module-cache-path',str(out/('SymbolModuleCache-Simulator' if args.simulator else 'SymbolModuleCache'))]
simulator = None
if args.simulator:
 simctl = str(xcode/'usr/bin/simctl')
 devices = json.loads(subprocess.check_output([simctl,'list','devices','available','--json'],env=env,text=True))
 booted = [d['udid'] for group in devices['devices'].values() for d in group if d['state']=='Booted']
 if env.get('SPEKTRACAM_SIMULATOR_ID'): booted=[d for d in booted if d==env['SPEKTRACAM_SIMULATOR_ID']]
 if not booted: raise SystemExit('Boot a Simulator before using --simulator.')
 simulator = [simctl,'spawn',booted[0]]
 compiler += ['-target',platform.machine()+'-apple-ios27.2-simulator']
for name in args.checks or [key for key in checks if not key.startswith('metal-') and not key.endswith('-benchmark') and key not in ['raw-input','processed-export','stress-export','bypass','tone-response']]:
 files,arguments=checks[name];binary=out/(name+'-checks'+('-simulator' if args.simulator else ''))
 subprocess.run(compiler+(['-O'] if name.endswith('-benchmark') and not args.debug_benchmarks else [])+[str(sources[f]) for f in files]+[str(root/'Scripts'/(name+'-checks.swift')),'-o',str(binary)],env=env,check=True)
 env['SPEKTRAFILM_BENCHMARK_CONFIGURATION']='debug' if args.debug_benchmarks else 'optimized'
 subprocess.run((simulator or [])+[str(binary)]+[str(root/a) for a in arguments]+(args.input if name in ['raw-input','processed-export','stress-export','bypass','tone-response','library','lut','preview','sdr-pipeline','render-cache'] else []),env=env,check=True)
