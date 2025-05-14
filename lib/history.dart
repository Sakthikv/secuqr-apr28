import 'dart:convert';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile.dart';
import 'package:flutter/material.dart';
import 'barcode_scanner_view.dart';

// class MyApp extends StatelessWidget {
//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       debugShowCheckedModeBanner: false,
//       home: HomePage(),
//     );
//   }
// }

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> _scanHistory = [];
  String _selectedFilter = 'All'; // default filter
  int count=0;
  int counterfeitCount=0;

  @override
  void initState() {
    super.initState();
    _loadScanHistory();
  }

  Future<void> _loadScanHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> historyList = prefs.getStringList('scanHistory') ?? [];
    setState(() {
      _scanHistory = historyList
          .map((item) => json.decode(item) as Map<String, dynamic>)
          .toList()
          .reversed
          .toList(); // optional: newest first
      count=historyList.length;
      counterfeitCount = _scanHistory.where((item) => item['status'] == 'Counterfeit').length;

    });
  }

  int _selectedIndex = 0;

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Existing Layout
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: [
                  // Greeting and Profile Image
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Hello!',
                            style: TextStyle(
                                fontSize: 28, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'SecuQR India',
                            style: TextStyle(
                                fontSize: 16, color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black, width: 2),
                        ),
                        child: CircleAvatar(
                          radius: 35,
                          backgroundImage:
                          AssetImage('images/secuqr_main_logo.png'),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 30),
                  // Scanned and Counterfeits Cards
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildStatCard(
                          icon: Icons.qr_code_scanner_outlined,
                          label: 'Scanned',
                          count: count,
                          color: Colors.blue.shade50),
                      _buildStatCard(
                          icon: Icons.error_outline,
                          label: 'Counterfeits',
                          count: counterfeitCount,
                          color: Colors.red.shade50),
                    ],
                  ),
                  SizedBox(height: 30),
                  // Scan History Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Scan History',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Icon(Icons.filter_list, color: Colors.black54),
                    ],
                  ),
                  SizedBox(height: 10),
                  // Filter Buttons
                  Row(
                    children: [
                      _buildFilterButton('All Scans', _selectedFilter == 'All'),
                      SizedBox(width: 10),
                      _buildFilterButton('Counterfeits', _selectedFilter == 'Counterfeit'),
                    ],
                  ),

                  SizedBox(height: 20),
                  Column(
                    children: _scanHistory
                        .where((item) =>
                    _selectedFilter == 'All' || item['status'] == 'Counterfeit')
                        .map((item) {

                      final imageBytes = base64Decode(item['image']);
                      final status = item['status'];
                      final datetime = item['dateTime'];

                      return GestureDetector(
                        onTap: () {
                          showDialog(

                            context: context,
                            builder: (_) =>
                                Dialog(
                                  backgroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16)),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                              12),
                                          child: Image.memory(imageBytes),
                                        ),
                                        SizedBox(height: 10),
                                        RichText(
                                          text: TextSpan(
                                            children: [
                                              TextSpan(
                                                text: 'Status: ',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.black,
                                                ),
                                              ),
                                              TextSpan(
                                                text: status,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: status == 'Counterfeit'
                                                      ? Colors.red
                                                      : status == 'Genuine'
                                                      ? Colors.green
                                                      : status == 'Error'
                                                      ? Color(0xFFEED508)
                                                      : Colors.black,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),


                                        Text('Scanned: $datetime',
                                            style: TextStyle(
                                                color: Colors.grey.shade600)),
                                        SizedBox(height: 10),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.teal
                                                  .shade600),
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          child: Text("Close", style: TextStyle(
                                              color: Colors.white),),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                          );
                        },
                        child: Container(
                          margin: EdgeInsets.only(bottom: 16),
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.teal.shade100),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 70,
                                height: 70,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  image: DecorationImage(
                                    image: MemoryImage(imageBytes),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    RichText(
                                      text: TextSpan(
                                        children: [
                                          TextSpan(
                                            text: 'Status: ',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Colors.black,
                                            ),
                                          ),
                                          TextSpan(
                                            text: status,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: status == 'Counterfeit'
                                                  ? Colors.red
                                                  : status == 'Genuine'
                                                  ? Colors.green
                                                  : status == 'Error'
                                                  ? Color(0xFFEED508)
                                                  : Colors.black,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Scanned: $datetime',
                                      style: TextStyle(
                                          color: Colors.grey.shade600),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                ],
              ),
            ),
          ),

        ],
      ),
      // Bottom Navigation Bar
      bottomNavigationBar: BottomAppBar(
        color: Colors.white,
        child: Container(
          height: 70, // Slightly increased height for better spacing
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              GestureDetector(
                onTap: () {

                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FontAwesomeIcons.clock),
                    Text(
                      "History",
                      style: TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0092B4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: const Icon(
                        Icons.qr_code_scanner, color: Colors.white),
                    onPressed: () {
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const BarcodeScannerView(),
                        ),
                            (route) => false,
                      );
                    },
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (_, __, ___) => ProfileApp(),
                      transitionDuration: const Duration(milliseconds: 20),
                      transitionsBuilder: (_, animation, __, child) {
                        return FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                      },
                    ),
                        (route) => false,
                  );
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FontAwesomeIcons.link),
                    Text(
                      "Connect",
                      style: TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),

    );
  }

  Widget _buildStatCard({required IconData icon,
    required String label,
    required int count,
    required Color color}) {
    return Container(
      width: MediaQuery
          .of(context)
          .size
          .width * 0.42,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: Colors.teal),
          SizedBox(height: 10),
          Text(
            label,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          Text('$count', style: TextStyle(fontSize: 20)),
        ],
      ),
    );
  }

  Widget _buildFilterButton(String text, bool isActive) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedFilter = text == 'All Scans' ? 'All' : 'Counterfeit';

          });
        },
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? Colors.teal : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.teal),
          ),
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.teal,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}