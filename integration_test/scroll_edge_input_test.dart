import 'package:integration_test/integration_test.dart';
import '../test/scroll_edge_input_test.dart' as checks;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  checks.main(native: true);
}
