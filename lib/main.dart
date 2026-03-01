import 'dart:async';
import 'package:web/web.dart' as web;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/intl.dart';
import 'firebase_options.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. .env 로드
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print("환경 변수 로드 실패: $e");
  }

  final String googleMapsKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? "";

  // 2. 구글 맵 스크립트 주입
  if (googleMapsKey.isNotEmpty) {
    final head = web.document.getElementsByTagName('head').item(0) as web.HTMLHeadElement?;
    
    if (head != null) {
      final script = web.HTMLScriptElement()
        ..src = "https://maps.googleapis.com/maps/api/js?key=$googleMapsKey"
        ..id = "google-maps-script";
      head.append(script);
      print("Google Maps Script Injected.");
    } else {
      final body = web.document.body;
      if (body != null) {
        final script = web.HTMLScriptElement()
          ..src = "https://maps.googleapis.com/maps/api/js?key=$googleMapsKey";
        body.append(script);
      }
    }
  }

  // 3. Firebase 초기화 및 ✅ 오프라인 캐시(로컬 저장소) 활성화
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // 이 한 줄로 쿠키 대신 파이어베이스 자체 캐시를 사용하여 로딩 속도를 비약적으로 높입니다.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
    );
  } catch (e) {
    print("Firebase 초기화 에러: $e");
  }

  runApp(const MaterialApp(
    title: '위치 확인 서비스',
    debugShowCheckedModeBanner: false,
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
  String _lastUpdateStr = "데이터 불러오는 중...";
  
  bool _isTrackingMode = true; // 화면 고정 모드 상태 변수
  bool _isAnimatingCamera = false; // ✅ 코드가 지도를 움직이는 중인지 체크하는 깃발

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
            child: Stack(
              children: [
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('locations')
                      .orderBy('timestamp', descending: true)
                      .limit(100)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting && _currentCenter == null) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final rawDocs = snapshot.data?.docs ?? [];
                    final docs = rawDocs.reversed.toList(); 

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
                          if (data['timestamp'] != null) {
                            final DateTime time = (data['timestamp'] as Timestamp).toDate();
                            _lastUpdateStr = DateFormat('MM/dd HH:mm:ss').format(time);
                          }

                          // ✅ [핵심 기능] 고정 모드일 때 내비게이션처럼 최신 위치로 계속 카메라 이동
                          if (_isTrackingMode) {
                            // 화면 렌더링이 꼬이지 않게 안전하게 실행
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _moveCamera(latLng);
                            });
                          }
                        }

                        markers.add(Marker(
                          markerId: MarkerId(docs[i].id),
                          position: latLng,
                          infoWindow: isLast ? InfoWindow(title: "최신 위치", snippet: _lastUpdateStr) : InfoWindow.noText,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            isLast ? BitmapDescriptor.hueRed : BitmapDescriptor.hueAzure,
                          ),
                          alpha: isLast ? 1.0 : 0.5,
                          zIndex: isLast ? 2.0 : 1.0, 
                        ));
                      }

                      polylines.add(Polyline(
                        polylineId: const PolylineId("path"),
                        points: polylinePoints,
                        color: Colors.blueAccent.withOpacity(0.8),
                        width: 5,
                      ));
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
                      // ✅ [핵심 해결] '코드가 움직일 때'는 자유 모드로 풀리지 않게 방어
                      onCameraMoveStarted: () {
                        if (_isTrackingMode && !_isAnimatingCamera) {
                          setState(() { _isTrackingMode = false; });
                        }
                      },
                    );
                  },
                ),
                // 모드 전환 플로팅 버튼
                Positioned(
                  top: 16,
                  right: 16,
                  child: FloatingActionButton.extended(
                    onPressed: () {
                      setState(() {
                        _isTrackingMode = !_isTrackingMode;
                        // 고정 모드로 돌아올 때 즉시 카메라를 당겨옴
                        if (_isTrackingMode && _currentCenter != null) {
                          _moveCamera(_currentCenter!);
                        }
                      });
                    },
                    backgroundColor: _isTrackingMode ? Colors.blueAccent : Colors.white,
                    foregroundColor: _isTrackingMode ? Colors.white : Colors.blueAccent,
                    icon: Icon(_isTrackingMode ? Icons.gps_fixed : Icons.explore),
                    label: Text(_isTrackingMode ? "화면 고정 중" : "자유 이동 모드"),
                  ),
                ),
              ],
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
      decoration: const BoxDecoration(
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
                icon: const Icon(Icons.touch_app),
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

  // ✅ 개선된 카메라 이동 로직 (플래그 사용)
  Future<void> _moveCamera(LatLng pos) async {
    if (!mounted) return;
    
    _isAnimatingCamera = true; // 코드로 움직인다고 시스템에 선언!
    
    final GoogleMapController controller = await _controller.future;
    await controller.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
    
    // 애니메이션이 끝날 즈음 플래그 해제 (안전하게 1.5초 대기)
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) {
        _isAnimatingCamera = false;
      }
    });
  }

  // 앱에 즉시 전송 명령 하달
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