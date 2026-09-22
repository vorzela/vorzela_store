import 'package:vorzela_json/vorzela_json.dart';
import 'package:vorzela_store/vorzela_store.dart';

class Profile extends JsonModel {
  Profile([super.data]);
  Profile.fromJson(super.json) : super.fromJson();
}

Future<void> openDurable() async {
  await VorzStore.open(name: 'app');
}

Future<void> openModels(VorzStore store) async {
  await store.models('users', fromJson: Profile.fromJson);
}

Future<void> wipeAndClose(VorzStore store) async {
  await store.wipeKeys();
  await store.close();
}
