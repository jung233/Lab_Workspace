import '../domain/json_value.dart';
import 'calculation_pack.dart';

/// Source-controlled built-ins. The private constructor prevents an AI draft or
/// caller-supplied document from self-asserting trusted-built-in status.
final class BuiltInCalculationPack {
  BuiltInCalculationPack._({
    required Map<String, Object?> document,
    required Map<String, Object?> forms,
  })  : document = freezeJsonObject(document),
        forms = freezeJsonObject(forms),
        contentSha256 = calculationPackContentSha256(document) {
    if (document['status'] != 'approved') {
      throw const FormatException('Built-in Calculation Packs must be versioned as approved.');
    }
  }

  final Map<String, Object?> document;
  final Map<String, Object?> forms;
  final String contentSha256;

  String get packId => document['pack_id']! as String;
  String get version => document['version']! as String;
  String get ref => '$packId@$version';
}

final class BuiltInCalculationPackCatalog {
  BuiltInCalculationPackCatalog._();

  static final List<BuiltInCalculationPack> all = List.unmodifiable([
    BuiltInCalculationPack._(
      document: _bca,
      forms: _bcaForms,
    ),
    BuiltInCalculationPack._(
      document: _wbLoading,
      forms: _wbLoadingForms,
    ),
    BuiltInCalculationPack._(
      document: _wbNormalization,
      forms: _wbNormalizationForms,
    ),
  ]);

  static BuiltInCalculationPack? find(String packId, String version) {
    for (final pack in all) {
      if (pack.packId == packId && pack.version == version) return pack;
    }
    return null;
  }
}

const Map<String, Object?> _bca = {
  'schema_version': '2.0',
  'pack_id': 'org.labworkspace.calc.bca-standard-curve',
  'version': '1.0.0',
  'kind': 'calculation',
  'status': 'approved',
  'title': 'BCA standard curve and dilution correction',
  'inputs': [
    {'key': 'standards', 'kind': 'table', 'required': true},
    {'key': 'sample_absorbance', 'kind': 'decimal', 'unit': 'AU', 'required': true},
    {'key': 'blank_absorbance', 'kind': 'decimal', 'unit': 'AU', 'required': true},
    {'key': 'dilution_factor', 'kind': 'decimal', 'unit': '1', 'required': true},
  ],
  'pipeline': [
    {
      'step_id': 'adjust_standards',
      'op': 'bca.blank_adjust@1',
      'inputs': {'standards': r'$inputs.standards', 'blank': r'$inputs.blank_absorbance'},
      'params': {
        'concentration_key': 'concentration',
        'absorbance_key': 'absorbance',
        'concentration_unit': 'ug/mL',
        'absorbance_unit': 'AU',
      },
    },
    {
      'step_id': 'sample_net',
      'op': 'math.subtract@1',
      'inputs': {'a': r'$inputs.sample_absorbance', 'b': r'$inputs.blank_absorbance'},
      'params': {},
    },
    {
      'step_id': 'fit',
      'op': 'stats.linear_regression@1',
      'inputs': {'standards': r'$steps.adjust_standards.standards'},
      'params': {
        'x_key': 'concentration',
        'y_key': 'absorbance',
        'x_unit': 'ug/mL',
        'y_unit': 'AU',
      },
    },
    {
      'step_id': 'sample_concentration',
      'op': 'math.linear_inverse@1',
      'inputs': {
        'y': r'$steps.sample_net.value',
        'slope': r'$steps.fit.slope',
        'intercept': r'$steps.fit.intercept',
      },
      'params': {},
    },
    {
      'step_id': 'qc',
      'op': 'data.qc_range@1',
      'inputs': {
        'x': r'$steps.sample_concentration.value',
        'low': r'$steps.fit.min_x',
        'high': r'$steps.fit.max_x',
      },
      'params': {
        'warning': 'Sample concentration falls outside the fitted standard range; manual review is required.',
      },
    },
    {
      'step_id': 'diluted',
      'op': 'math.multiply@1',
      'inputs': {
        'a': r'$steps.sample_concentration.value',
        'b': r'$inputs.dilution_factor',
      },
      'params': {},
    },
    {
      'step_id': 'convert',
      'op': 'math.unit_convert@1',
      'inputs': {'value': r'$steps.diluted.value'},
      'params': {'factor': '0.001', 'from': 'ug/mL', 'to': 'mg/mL'},
    },
  ],
  'outputs': [
    {'key': 'protein_concentration', 'from_ref': r'$steps.convert.value', 'unit': 'mg/mL'},
    {'key': 'r_squared', 'from_ref': r'$steps.fit.r_squared', 'unit': '1'},
    {'key': 'within_standard_range', 'from_ref': r'$steps.qc.in_range', 'unit': null},
  ],
  'quality_gates': [
    {
      'id': 'bca_range',
      'expression_ref': r'$steps.qc.in_range',
      'severity': 'warn',
      'message': 'The sample is outside the fitted standard range; inspect the curve and sample dilution.',
    },
  ],
  'tests': [
    {
      'name': 'synthetic_linear_example',
      'inputs': {
        'standards': [
          {'concentration': '0', 'absorbance': '0.04'},
          {'concentration': '200', 'absorbance': '0.24'},
          {'concentration': '400', 'absorbance': '0.44'},
        ],
        'sample_absorbance': '0.34',
        'blank_absorbance': '0.04',
        'dilution_factor': '5',
      },
      'expected': {'protein_concentration': '1.5', 'r_squared': '1', 'within_standard_range': true},
      'tolerance': {'protein_concentration': '0.0000001', 'r_squared': '0.0000001'},
    },
  ],
  'review': {
    'approved_by_user': false,
    'warnings': [
      'Synthetic reference pack only. Select the assay kit protocol, standard concentrations, and instrument method in the approved experiment procedure.',
    ],
  },
};

const Map<String, Object?> _bcaForms = {
  'schema_version': '2.0',
  'title': 'BCA standard curve',
  'fields': [
    {'key': 'standards', 'label': 'Standard concentration and absorbance table', 'widget': 'table', 'required': true},
    {'key': 'sample_absorbance', 'label': 'Sample absorbance', 'widget': 'decimal', 'unit': 'AU', 'required': true},
    {'key': 'blank_absorbance', 'label': 'Blank absorbance', 'widget': 'decimal', 'unit': 'AU', 'required': true},
    {'key': 'dilution_factor', 'label': 'Sample dilution factor', 'widget': 'decimal', 'unit': '1', 'required': true},
  ],
  'outputs': [
    {'key': 'protein_concentration', 'label': 'Protein concentration', 'unit': 'mg/mL', 'show_trace_button': true},
    {'key': 'r_squared', 'label': 'Linear fit R²', 'unit': '1', 'show_trace_button': true},
    {'key': 'within_standard_range', 'label': 'Within fitted range', 'unit': null, 'show_trace_button': true},
  ],
  'warning': 'The BCA curve and dilution factor are visible in 展示原始计算. This reference pack does not replace kit-specific validation.',
};

const Map<String, Object?> _wbLoading = {
  'schema_version': '2.0',
  'pack_id': 'org.labworkspace.calc.wb-loading-volume',
  'version': '1.0.0',
  'kind': 'calculation',
  'status': 'approved',
  'title': 'Western blot sample loading volume',
  'inputs': [
    {'key': 'target_protein_mass', 'kind': 'decimal', 'unit': 'ug', 'required': true},
    {'key': 'protein_concentration', 'kind': 'decimal', 'unit': 'ug/uL', 'required': true},
    {'key': 'maximum_sample_volume', 'kind': 'decimal', 'unit': 'uL', 'required': true},
  ],
  'pipeline': [
    {
      'step_id': 'sample_volume',
      'op': 'math.divide@1',
      'inputs': {
        'numerator': r'$inputs.target_protein_mass',
        'denominator': r'$inputs.protein_concentration',
      },
      'params': {},
    },
    {
      'step_id': 'volume_qc',
      'op': 'data.qc_range@1',
      'inputs': {
        'x': r'$steps.sample_volume.value',
        'low': '0',
        'high': r'$inputs.maximum_sample_volume',
      },
      'params': {
        'unit': 'uL',
        'warning': 'Calculated sample volume exceeds the declared maximum loading volume; manual review is required.',
      },
    },
  ],
  'outputs': [
    {'key': 'sample_volume', 'from_ref': r'$steps.sample_volume.value', 'unit': 'uL'},
    {'key': 'within_maximum_volume', 'from_ref': r'$steps.volume_qc.in_range', 'unit': null},
  ],
  'quality_gates': [
    {
      'id': 'volume_limit',
      'expression_ref': r'$steps.volume_qc.in_range',
      'severity': 'warn',
      'message': 'Calculated volume exceeds the explicitly entered maximum loading volume.',
    },
  ],
  'tests': [
    {
      'name': 'synthetic_twenty_micrograms_at_two_micrograms_per_microliter',
      'inputs': {
        'target_protein_mass': '20',
        'protein_concentration': '2',
        'maximum_sample_volume': '10',
      },
      'expected': {'sample_volume': '10', 'within_maximum_volume': true},
      'tolerance': {'sample_volume': '0.0000001'},
    },
  ],
  'review': {
    'approved_by_user': false,
    'warnings': [
      'Confirm target mass, confirmed BCA concentration, and loading constraints from the local Western blot procedure.',
    ],
  },
};

const Map<String, Object?> _wbLoadingForms = {
  'schema_version': '2.0',
  'title': 'Western blot loading volume',
  'fields': [
    {'key': 'target_protein_mass', 'label': 'Target protein mass', 'widget': 'decimal', 'unit': 'ug', 'required': true},
    {'key': 'protein_concentration', 'label': 'Confirmed protein concentration', 'widget': 'decimal', 'unit': 'ug/uL', 'required': true},
    {'key': 'maximum_sample_volume', 'label': 'Maximum sample volume from procedure', 'widget': 'decimal', 'unit': 'uL', 'required': true},
  ],
  'outputs': [
    {'key': 'sample_volume', 'label': 'Sample volume', 'unit': 'uL', 'show_trace_button': true},
    {'key': 'within_maximum_volume', 'label': 'Within maximum volume', 'unit': null, 'show_trace_button': true},
  ],
  'warning': 'This pack calculates target mass divided by protein concentration. It does not choose a target mass or total loading volume.',
};

const Map<String, Object?> _wbNormalization = {
  'schema_version': '2.0',
  'pack_id': 'org.labworkspace.calc.wb-normalization',
  'version': '1.0.0',
  'kind': 'calculation',
  'status': 'approved',
  'title': 'Western blot ROI normalization',
  'inputs': [
    {'key': 'target_intensity', 'kind': 'decimal', 'unit': 'intensity', 'required': true},
    {'key': 'reference_intensity', 'kind': 'decimal', 'unit': 'intensity', 'required': true},
    {'key': 'calibrator_ratio', 'kind': 'decimal', 'unit': '1', 'required': true},
  ],
  'pipeline': [
    {
      'step_id': 'normalized',
      'op': 'wb.normalize_ratio@1',
      'inputs': {
        'target_intensity': r'$inputs.target_intensity',
        'reference_intensity': r'$inputs.reference_intensity',
        'calibrator_ratio': r'$inputs.calibrator_ratio',
      },
      'params': {
        'method_warning': 'Confirm that ROI selection, loading control, and calibrator follow the approved imaging procedure.',
      },
    },
  ],
  'outputs': [
    {'key': 'sample_ratio', 'from_ref': r'$steps.normalized.ratio', 'unit': '1'},
    {'key': 'relative_ratio', 'from_ref': r'$steps.normalized.relative_ratio', 'unit': '1'},
  ],
  'quality_gates': [],
  'tests': [
    {
      'name': 'synthetic_ratio',
      'inputs': {'target_intensity': '200', 'reference_intensity': '100', 'calibrator_ratio': '1'},
      'expected': {'sample_ratio': '2', 'relative_ratio': '2'},
      'tolerance': {'sample_ratio': '0.0000001', 'relative_ratio': '0.0000001'},
    },
  ],
  'review': {
    'approved_by_user': false,
    'warnings': [
      'Input intensities must come from explicitly approved ROIs on immutable original pixels. This pack does not detect or segment bands.',
    ],
  },
};

const Map<String, Object?> _wbNormalizationForms = {
  'schema_version': '2.0',
  'title': 'Western blot ratio normalization',
  'fields': [
    {'key': 'target_intensity', 'label': 'Target ROI integrated intensity', 'widget': 'decimal', 'unit': 'intensity', 'required': true},
    {'key': 'reference_intensity', 'label': 'Reference ROI integrated intensity', 'widget': 'decimal', 'unit': 'intensity', 'required': true},
    {'key': 'calibrator_ratio', 'label': 'Confirmed calibrator ratio', 'widget': 'decimal', 'unit': '1', 'required': true},
  ],
  'outputs': [
    {'key': 'sample_ratio', 'label': 'Target/reference ratio', 'unit': '1', 'show_trace_button': true},
    {'key': 'relative_ratio', 'label': 'Ratio relative to calibrator', 'unit': '1', 'show_trace_button': true},
  ],
  'warning': 'ROI data must be linked to a reviewed, immutable original image and ROI approval trace.',
};
