import 'package:flutter/material.dart';
class MySearchDelegate extends SearchDelegate<void> {
  @override
  List<Widget>? buildActions(BuildContext context) => null;
  @override
  Widget? buildLeading(BuildContext context) => null;
  @override
  Widget buildResults(BuildContext context) => Container();
  @override
  Widget buildSuggestions(BuildContext context) => Container();
  
  void test() {
    print(query);
  }
}
