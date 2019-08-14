import 'package:angel_framework/angel_framework.dart';
import 'package:angel_framework/http.dart';
import 'package:angel_security/angel_security.dart';

main() async {
  // Create an app, and HTTP driver.
  var app = Angel(), http = AngelHttp(app);

  // Create a simple in-memory rate limiter that limits users to 5
  // queries per hour.
  //
  // In this case, we rate limit users by IP address.
  var rateLimiter =
      InMemoryRateLimiter(5, Duration(hours: 1), (req, res) => req.ip);

  // `RateLimiter.handleRequest` is a middleware, and can be used anywhere
  // a middleware can be used. In this case, we apply the rate limiter to
  // *all* incoming requests.
  app.fallback(rateLimiter.handleRequest);

  // Basic routes.
  app
    ..get('/', (req, res) => 'Hello!')
    ..fallback((req, res) => throw AngelHttpException.notFound());

  // Start the server.
  await http.startServer('127.0.0.1', 3000);
  print('Rate limiting example listening at ${http.uri}');
}
