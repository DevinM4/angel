library angel_route.src.router;

import 'extensible.dart';
import 'routing_exception.dart';
part 'symlink_route.dart';
part 'route.dart';
part 'routing_result.dart';

final RegExp _param = new RegExp(r':([A-Za-z0-9_]+)(\((.+)\))?');
final RegExp _rgxEnd = new RegExp(r'\$+$');
final RegExp _rgxStart = new RegExp(r'^\^+');
final RegExp _rgxStraySlashes =
    new RegExp(r'(^((\\+/)|(/))+)|(((\\+/)|(/))+$)');
final RegExp _slashDollar = new RegExp(r'/+\$');
final RegExp _straySlashes = new RegExp(r'(^/+)|(/+$)');

/// An abstraction over complex [Route] trees. Use this instead of the raw API. :)
class Router {
  final List _middleware = [];
  final Map<Pattern, Router> _mounted = {};
  final List<Route> _routes = [];

  /// Set to `true` to print verbose debug output when interacting with this route.
  bool debug = false;

  List get middleware => new List.unmodifiable(_middleware);

  Map<Pattern, Router> get mounted =>
      new Map<Pattern, Router>.unmodifiable(_mounted);

  /// Additional filters to be run on designated requests.
  Map<String, dynamic> requestMiddleware = {};

  List<Route> get routes => new List<Route>.unmodifiable(_routes);

  /// Provide a `root` to make this Router revolve around a pre-defined route.
  /// Not recommended.
  Router({this.debug: false});

  void _printDebug(msg) {
    if (debug == true) print(msg);
  }

  /// Adds a route that responds to the given path
  /// for requests with the given method (case-insensitive).
  /// Provide '*' as the method to respond to all methods.
  Route addRoute(String method, Pattern path, Object handler,
      {List middleware: const []}) {
    // Check if any mounted routers can match this
    final handlers = [handler];

    if (middleware != null) handlers.addAll(middleware);

    final route =
        new Route(path, debug: debug, method: method, handlers: handlers);
    _routes.add(route);
    return route;
  }

  /// Returns a [Router] with a duplicated version of this tree.
  Router clone() {
    final router = new Router(debug: debug);
    final newMounted = new Map.from(mounted);

    for (Route route in routes) {
      if (route is! SymlinkRoute) {
        router._routes.add(route.clone());
      } else if (route is SymlinkRoute) {
        final newRouter = route.router.clone();
        newMounted[route.path] = newRouter;
        final symlink = new SymlinkRoute(route.path, route.pattern, newRouter)
          .._head = route._head;
        router._routes.add(symlink);
      }
    }

    return router.._mounted.addAll(newMounted);
  }

  /// Creates a visual representation of the route hierarchy and
  /// passes it to a callback. If none is provided, `print` is called.
  void dumpTree(
      {callback(String tree),
      String header: 'Dumping route tree:',
      String tab: '  ',
      bool showMatchers: false}) {
    final buf = new StringBuffer();
    int tabs = 0;

    if (header != null && header.isNotEmpty) {
      buf.writeln(header);
    }

    buf.writeln('<root>');

    indent() {
      for (int i = 0; i < tabs; i++) buf.write(tab);
    }

    dumpRouter(Router router) {
      indent();
      tabs++;

      for (Route route in router.routes) {
        indent();
        buf.write('- ${route.path.isNotEmpty ? route.path : '/'}');

        if (route is SymlinkRoute) {
          buf.writeln();
          dumpRouter(route.router);
        } else {
          if (showMatchers) buf.write(' (${route.matcher.pattern})');

          buf.writeln(' => ${route.handlers.length} handler(s)');
        }
      }

      tabs--;
    }

    dumpRouter(this);

    (callback ?? print)(buf.toString());
  }

  /// Creates a route, and allows you to add child routes to it
  /// via a [Router] instance.
  ///
  /// Returns the created route.
  /// You can also register middleware within the router.
  SymlinkRoute group(Pattern path, void callback(Router router),
      {Iterable middleware: const [],
      String name: null,
      String namespace: null}) {
    final router = new Router(debug: debug).._middleware.addAll(middleware);
    callback(router);

    return mount(path, router, namespace: namespace).._name = name;
  }

  /// Generates a URI string based on the given input.
  /// Handy when you have named routes.
  ///
  /// Each item in `linkParams` should be a [Route],
  /// `String` or `Map<String, dynamic>`.
  ///
  /// Strings should be route names, namespaces, or paths.
  /// Maps should be parameters, which will be filled
  /// into the previous route.
  ///
  /// Paths and segments should correspond to the way
  /// you declared them.
  ///
  /// For example, if you declared a route group on
  /// `'users/:id'`, it would not be resolved if you
  /// passed `'users'` in [linkParams].
  ///
  /// Leading and trailing slashes are automatically
  /// removed.
  ///
  /// Set [absolute] to `true` to insert a forward slash
  /// before the generated path.
  ///
  /// Example:
  /// ```dart
  /// router.navigate(['users/:id', {'id': '1337'}, 'profile']);
  /// ```
  String navigate(List linkParams, {bool absolute: true}) {
    final List<String> segments = [];
    Router search = this;
    Route lastRoute;

    for (final param in linkParams) {
      bool resolved = false;

      if (param is String) {
        // Search by name
        for (Route route in search.routes) {
          if (route.name == param) {
            segments.add(route.path.replaceAll(_straySlashes, ''));
            lastRoute = route;

            if (route is SymlinkRoute) {
              search = route.router;
            }

            resolved = true;
            break;
          }
        }

        // Search by path
        for (Route route in search.routes) {
          if (route.match(param) != null) {
            segments.add(route.path.replaceAll(_straySlashes, ''));
            lastRoute = route;

            if (route is SymlinkRoute) {
              search = route.router;
            }

            resolved = true;
            break;
          }
        }

        if (!resolved) {
          throw new RoutingException(
              'Cannot resolve route for link param "$param".');
        }
      } else if (param is Route) {
        segments.add(param.path.replaceAll(_straySlashes, ''));
      } else if (param is Map<String, dynamic>) {
        if (lastRoute == null) {
          throw new RoutingException(
              'Maps in link params must be preceded by a Route or String.');
        } else {
          segments.removeLast();
          segments.add(lastRoute.makeUri(param).replaceAll(_straySlashes, ''));
        }
      } else
        throw new RoutingException(
            'Link param $param is not Route, String, or Map<String, dynamic>.');
    }

    return absolute
        ? '/${segments.join('/').replaceAll(_straySlashes, '')}'
        : segments.join('/');
  }

  /// Assigns a middleware to a name for convenience.
  registerMiddleware(String name, middleware) {
    requestMiddleware[name] = middleware;
  }

  RoutingResult _dumpResult(String path, RoutingResult result) {
    _printDebug('Resolved "/$path" to ${result.deepestRoute}');
    return result;
  }

  /// Finds the first [Route] that matches the given path,
  /// with the given method.
  RoutingResult resolve(String fullPath, String path, {String method: 'GET'}) {
    final cleanFullPath = fullPath.replaceAll(_straySlashes, '');
    final cleanPath = path.replaceAll(_straySlashes, '');
    _printDebug(
        'Now resolving $method "/$cleanPath", fullPath: $cleanFullPath');

    for (Route route in routes) {
      if (route is SymlinkRoute && route._head != null) {
        final match = route._head.firstMatch(cleanPath);

        if (match != null) {
          final tail = cleanPath
              .replaceAll(route._head, '')
              .replaceAll(_straySlashes, '');
          _printDebug('Matched head "${match[0]}" to $route. Tail: "$tail"');
          route.router.debug = route.router.debug || debug;
          final nested =
              route.router.resolve(cleanFullPath, tail, method: method);
          return _dumpResult(
              cleanPath,
              new RoutingResult(
                  match: match,
                  nested: nested,
                  params: route.parseParameters(cleanPath),
                  sourceRoute: route,
                  sourceRouter: this,
                  tail: tail));
        }
      } else if (route.method == '*' || route.method == method) {
        final match = route.match(cleanPath);

        if (match != null) {
          return _dumpResult(
              cleanPath,
              new RoutingResult(
                  match: match,
                  params: route.parseParameters(cleanPath),
                  sourceRoute: route,
                  sourceRouter: this));
        }
      }
    }

    _printDebug('Could not resolve path "/$cleanPath".');
    return null;
  }

  /// Finds every possible [Route] that matches the given path,
  /// with the given method.
  Iterable<RoutingResult> resolveAll(String fullPath, String path,
      {String method: 'GET'}) {
    final router = clone();
    final List<RoutingResult> results = [];
    var result = router.resolve(fullPath, path, method: method);

    while (result != null) {
      if (!results.contains(result))
        results.add(result);
      else
        break;

      result.deepestRouter._routes.remove(result.deepestRoute);
      result = router.resolve(fullPath, path, method: method);
    }

    _printDebug(
        'Results of $method "/${fullPath.replaceAll(_straySlashes, '')}": ${results.map((r) => r.deepestRoute).toList()}');
    return results;
  }

  _validHead(RegExp rgx) {
    return !rgx.hasMatch('');
  }

  /// Incorporates another [Router]'s routes into this one's.
  ///
  /// If `hooked` is set to `true` and a [Service] is provided,
  /// then that service will be wired to a [HookedService] proxy.
  /// If a `namespace` is provided, then any middleware
  /// from the provided [Router] will be prefixed by that namespace,
  /// with a dot.
  /// For example, if the [Router] has a middleware 'y', and the `namespace`
  /// is 'x', then that middleware will be available as 'x.y' in the main router.
  /// These namespaces can be nested.
  SymlinkRoute mount(Pattern path, Router router,
      {bool hooked: true, String namespace: null}) {
    // Let's copy middleware, heeding the optional middleware namespace.
    String middlewarePrefix = namespace != null ? "$namespace." : "";

    Map copiedMiddleware = new Map.from(router.requestMiddleware);
    for (String middlewareName in copiedMiddleware.keys) {
      requestMiddleware["$middlewarePrefix$middlewareName"] =
          copiedMiddleware[middlewareName];
    }

    final route = new SymlinkRoute(path, path, router);
    _mounted[route.path] = router;
    _routes.add(route);
    route._head = new RegExp(route.matcher.pattern.replaceAll(_rgxEnd, ''));

    return route.._name = namespace;
  }

  /// Adds a route that responds to any request matching the given path.
  Route all(Pattern path, Object handler, {List middleware}) {
    return addRoute('*', path, handler, middleware: middleware);
  }

  /// Adds a route that responds to a DELETE request.
  Route delete(Pattern path, Object handler, {List middleware}) {
    return addRoute('DELETE', path, handler, middleware: middleware);
  }

  /// Adds a route that responds to a GET request.
  Route get(Pattern path, Object handler, {List middleware}) {
    return addRoute('GET', path, handler, middleware: middleware);
  }

  /// Adds a route that responds to a HEAD request.
  Route head(Pattern path, Object handler, {List middleware}) {
    return addRoute('HEAD', path, handler, middleware: middleware);
  }

  /// Adds a route that responds to a OPTIONS request.
  Route options(Pattern path, Object handler, {List middleware}) {
    return addRoute('OPTIONS', path, handler, middleware: middleware);
  }

  /// Adds a route that responds to a POST request.
  Route post(Pattern path, Object handler, {List middleware}) {
    return addRoute('POST', path, handler, middleware: middleware);
  }

  /// Adds a route that responds to a PATCH request.
  Route patch(Pattern path, Object handler, {List middleware}) {
    return addRoute('PATCH', path, handler, middleware: middleware);
  }

  /// Adds a route that responds to a PUT request.
  Route put(Pattern path, Object handler, {List middleware}) {
    return addRoute('PUT', path, handler, middleware: middleware);
  }
}
