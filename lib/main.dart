import 'dart:async';
import 'package:web/web.dart' as web;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/intl.dart';

// Firebase 설정 파일 (flutterfire configure 실행 후 생성됨)
import 'firebase_options.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. .env 파일에서 API 키 로드
  await dotenv.load(fileName: ".env");
  final String googleMapsKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? "";

  // 2. 구글 맵 스크립트를 웹 헤더에 동적으로 주입 (보안 및 유연성)
  if (googleMapsKey.isNotEmpty) {
    final script = web.HTMLScriptElement()
      ..src = "https://maps.googleapis.com/maps/api/js?key=$googleMapsKey"
      ..id = "google-maps-script";
    // head 태그에 추가
    web.document.head?.append(script);
  }

  // 3. Firebase 초기화
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const MaterialApp(
    title: '가족 위치 확인 서비스',
    home: AuthGate(),
  ));
}

// --- 인증 문지기 (로그인 여부 확인) ---
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const LoginPage();
        return const FamilyMapPage();
      },
    );
  }
}

// --- 로그인 페이지 ---
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _pwController = TextEditingController();

  Future<void> _login() async {
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _pwController.text.trim(),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("로그인에 실패했습니다. 이메일과 비밀번호를 확인하세요.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Center(
        child: Card(
          elevation: 8,
          child: Container(
            width: 350,
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_person, size: 60, color: Colors.blue),
                const SizedBox(height: 16),
                const Text("회원 전용 로그인", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                TextField(controller: _emailController, decoration: const InputDecoration(labelText: "이메일")),
                TextField(controller: _pwController, decoration: const InputDecoration(labelText: "비밀번호"), obscureText: true),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(onPressed: _login, child: const Text("로그인")),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 메인 지도 화면 ---
class FamilyMapPage extends StatefulWidget {
  const FamilyMapPage({super.key});

  @override
  State<FamilyMapPage> createState() => _FamilyMapPageState();
}

class _FamilyMapPageState extends State<FamilyMapPage> {
  final Completer<GoogleMapController> _controller = Completer();
  LatLng? _currentCenter;
  String _lastUpdateStr = "-";
  bool _isFirstLoad = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("실시간 동선"),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: () => FirebaseAuth.instance.signOut(), icon: const Icon(Icons.logout))
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              // 최근 24시간 데이터 쿼리
              stream: FirebaseFirestore.instance
                  .collection('locations')
                  .where('timestamp', isGreaterThan: DateTime.now().subtract(const Duration(hours: 24)))
                  .orderBy('timestamp', descending: false)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data?.docs ?? [];
                Set<Marker> markers = {};
                Set<Polyline> polylines = {};
                List<LatLng> polylinePoints = [];

                if (docs.isNotEmpty) {
                  for (int i = 0; i < docs.length; i++) {
                    final data = docs[i].data() as Map<String, dynamic>;
                    final latLng = LatLng(data['latitude'], data['longitude']);
                    polylinePoints.add(latLng);

                    bool isLast = (i == docs.length - 1);
                    if (isLast) {
                      _currentCenter = latLng;
                      final DateTime time = (data['timestamp'] as Timestamp).toDate();
                      _lastUpdateStr = DateFormat('MM/dd HH:mm:ss').format(time);
                    }

                    markers.add(Marker(
                      markerId: MarkerId(docs[i].id),
                      position: latLng,
                      infoWindow: isLast ? InfoWindow(title: "현재 위치", snippet: _lastUpdateStr) : InfoWindow.noText,
                      icon: BitmapDescriptor.defaultMarkerWithHue(
                        isLast ? BitmapDescriptor.hueRed : BitmapDescriptor.hueAzure,
                      ),
                    ));
                  }

                  polylines.add(Polyline(
                    polylineId: const PolylineId("path"),
                    points: polylinePoints,
                    color: Colors.blue.withOpacity(0.7),
                    width: 4,
                  ));

                  // 첫 로딩 시 혹은 새로운 데이터가 왔을 때 카메라 이동
                  if (_isFirstLoad && _currentCenter != null) {
                    _moveCamera(_currentCenter!);
                    _isFirstLoad = false;
                  }
                }

                return GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _currentCenter ?? const LatLng(37.5665, 126.9780),
                    zoom: 16,
                  ),
                  markers: markers,
                  polylines: polylines,
                  onMapCreated: (controller) => _controller.complete(controller),
                  myLocationButtonEnabled: false,
                );
              },
            ),
          ),
          _buildStatusPanel(),
        ],
      ),
    );
  }

  // 하단 상태바 및 제어판
  Widget _buildStatusPanel() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -5))],
      ),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.access_time, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                Text("마지막 위치 확인: ", style: TextStyle(color: Colors.grey[700])),
                Text(_lastUpdateStr, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _sendInstantRequest,
                icon: const Icon(Icons.gps_fixed),
                label: const Text("즉시 현재 위치 요청 (강제 호출)", style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 카메라 이동 로직
  Future<void> _moveCamera(LatLng pos) async {
    final GoogleMapController controller = await _controller.future;
    controller.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
  }

  // 할아버지 앱에 즉시 전송 명령 하달
  void _sendInstantRequest() async {
    await FirebaseFirestore.instance.collection('commands').doc('request_location').set({
      'timestamp': FieldValue.serverTimestamp(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("대상 스마트폰에 위치 전송 명령을 보냈습니다.")),
    );
  }
}