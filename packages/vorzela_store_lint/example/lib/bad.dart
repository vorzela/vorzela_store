import 'package:path_provider/path_provider.dart';
import 'package:vorzela_json/vorzela_json.dart';
import 'package:vorzela_store/vorzela_store.dart';

class Profile extends JsonModel {
  Profile([super.data]);
  Profile.fromJson(super.json) : super.fromJson();
}

Future<void> openOnTmp() async {
  // expect_lint: avoid_temporary_directory_for_vorz_store
  await VorzStore.open(name: 'cache', directory: await getTemporaryDirectory());
}

Future<void> openInMemoryApp() async {
  // expect_lint: avoid_vorz_store_open_memory_in_app
  await VorzStore.openMemory(name: 'session');
}

Future<void> saveBytes(VorzCollection<Profile> col) async {
  // expect_lint: prefer_vorz_blob_store_for_bytes
  await col.put('p1', {'bytes': [9, 9]});
}

Future<void> openCollection(VorzStore store) async {
  // expect_lint: prefer_store_models_helper
  await store.collection('users', fromJson: Profile.fromJson);
}

Future<void> wipeOnly(VorzStore store) async {
  // expect_lint: prefer_wipe_keys_then_close
  await store.wipeKeys();
}
