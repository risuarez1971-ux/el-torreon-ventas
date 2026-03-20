import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

// ─────────────────────────────────────────────
// MODELO
// ─────────────────────────────────────────────

class Producto {
  final int? id;
  final String codigo;
  final String barra;
  final String desc;
  final String marca;
  final String mayor;
  final String minor;
  final String prov;

  const Producto({
    this.id,
    required this.codigo,
    required this.barra,
    required this.desc,
    required this.marca,
    required this.mayor,
    required this.minor,
    required this.prov,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'codigo': codigo,
        'barra': barra,
        'desc': desc,
        'marca': marca,
        'mayor': mayor,
        'minor': minor,
        'prov': prov,
      };

  factory Producto.fromMap(Map<String, dynamic> m) => Producto(
        id: m['id'] as int?,
        codigo: m['codigo'] as String? ?? '',
        barra: m['barra'] as String? ?? '',
        desc: m['desc'] as String? ?? '',
        marca: m['marca'] as String? ?? '',
        mayor: m['mayor'] as String? ?? '0,00',
        minor: m['minor'] as String? ?? '0,00',
        prov: m['prov'] as String? ?? '',
      );

  Producto copyWith({
    int? id,
    String? codigo,
    String? barra,
    String? desc,
    String? marca,
    String? mayor,
    String? minor,
    String? prov,
  }) =>
      Producto(
        id: id ?? this.id,
        codigo: codigo ?? this.codigo,
        barra: barra ?? this.barra,
        desc: desc ?? this.desc,
        marca: marca ?? this.marca,
        mayor: mayor ?? this.mayor,
        minor: minor ?? this.minor,
        prov: prov ?? this.prov,
      );
}

// ─────────────────────────────────────────────
// BASE DE DATOS (sqflite)
// ─────────────────────────────────────────────

class DatabaseService {
  static Database? _db;

  static Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, 'torreon.db');
    return openDatabase(
      fullPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE productos (
            id    INTEGER PRIMARY KEY AUTOINCREMENT,
            codigo TEXT,
            barra  TEXT,
            desc   TEXT,
            marca  TEXT,
            mayor  TEXT,
            minor  TEXT,
            prov   TEXT
          )
        ''');
        // Índices para búsqueda rápida
        await db.execute('CREATE INDEX idx_desc  ON productos(desc  COLLATE NOCASE)');
        await db.execute('CREATE INDEX idx_barra ON productos(barra)');
      },
    );
  }

  // Busca con LIKE en desc o barra, paginado
  static Future<List<Producto>> buscar(String query,
      {int limit = 60, int offset = 0}) async {
    final database = await db;
    final q = '%$query%';
    final rows = await database.query(
      'productos',
      where: 'desc LIKE ? OR barra LIKE ?',
      whereArgs: [q, q],
      orderBy: 'desc COLLATE NOCASE',
      limit: limit,
      offset: offset,
    );
    return rows.map(Producto.fromMap).toList();
  }

  // Lista completa paginada (sin filtro)
  static Future<List<Producto>> listar(
      {int limit = 60, int offset = 0}) async {
    final database = await db;
    final rows = await database.query(
      'productos',
      orderBy: 'desc COLLATE NOCASE',
      limit: limit,
      offset: offset,
    );
    return rows.map(Producto.fromMap).toList();
  }

  static Future<int> contar({String? query}) async {
    final database = await db;
    if (query == null || query.isEmpty) {
      final result =
          await database.rawQuery('SELECT COUNT(*) as c FROM productos');
      return result.first['c'] as int;
    }
    final q = '%$query%';
    final result = await database.rawQuery(
      'SELECT COUNT(*) as c FROM productos WHERE desc LIKE ? OR barra LIKE ?',
      [q, q],
    );
    return result.first['c'] as int;
  }

  static Future<void> insertar(Producto producto) async {
    final database = await db;
    await database.insert('productos', producto.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // Insert masivo en una sola transacción (para import)
  static Future<void> insertarLote(List<Producto> productos) async {
    final database = await db;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (final p in productos) {
        batch.insert('productos', p.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> actualizar(Producto producto) async {
    final database = await db;
    await database.update(
      'productos',
      producto.toMap(),
      where: 'id = ?',
      whereArgs: [producto.id],
    );
  }

  static Future<void> eliminar(int id) async {
    final database = await db;
    await database.delete('productos', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> eliminarTodos() async {
    final database = await db;
    await database.delete('productos');
  }

  static Future<List<Producto>> todos() async {
    final database = await db;
    final rows =
        await database.query('productos', orderBy: 'desc COLLATE NOCASE');
    return rows.map(Producto.fromMap).toList();
  }
}

// ─────────────────────────────────────────────
// PARSEO EN ISOLATE (no bloquea la UI)
// ─────────────────────────────────────────────

class _ParseArgs {
  final String path;
  final String ext;
  const _ParseArgs(this.path, this.ext);
}

List<Producto> _parsearArchivo(_ParseArgs args) {
  final file = File(args.path);
  final List<Producto> productos = [];

  if (args.ext == 'xlsx') {
    final bytes = file.readAsBytesSync();
    final excel = Excel.decodeBytes(bytes);
    for (final table in excel.tables.keys) {
      final rows = excel.tables[table]!.rows;
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.length >= 6) {
          productos.add(Producto(
            codigo: row[0]?.value?.toString() ?? '',
            barra: row[1]?.value?.toString() ?? '',
            desc: row[2]?.value?.toString() ?? '',
            marca: row[3]?.value?.toString() ?? '',
            mayor: (row[4]?.value?.toString() ?? '0,00').replaceAll('.', ','),
            minor: (row[5]?.value?.toString() ?? '0,00').replaceAll('.', ','),
            prov: row.length > 6 ? row[6]?.value?.toString() ?? '' : '',
          ));
        }
      }
      break; // Solo la primera hoja
    }
  } else if (args.ext == 'csv') {
    String input;
    try {
      input = file.readAsStringSync(encoding: utf8);
    } catch (_) {
      input = file.readAsStringSync(encoding: latin1);
    }
    final lineas = input.split('\n');
    for (var i = 1; i < lineas.length; i++) {
      final linea = lineas[i].trim();
      if (linea.isEmpty) continue;
      final campos = linea.split(';');
      if (campos.length >= 6) {
        productos.add(Producto(
          codigo: campos[0].trim(),
          barra: campos[1].trim(),
          desc: campos[2].trim(),
          marca: campos[3].trim(),
          mayor: campos[4].trim().replaceAll('.', ','),
          minor: campos[5].trim().replaceAll('.', ','),
          prov: campos.length > 6 ? campos[6].trim() : '',
        ));
      }
    }
  }

  return productos;
}

// ─────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────

void main() {
  runApp(const MaterialApp(
    home: ListaPreciosApp(),
    debugShowCheckedModeBanner: false,
  ));
}

// ─────────────────────────────────────────────
// APP PRINCIPAL
// ─────────────────────────────────────────────

class ListaPreciosApp extends StatefulWidget {
  const ListaPreciosApp({super.key});

  @override
  State<ListaPreciosApp> createState() => _ListaPreciosAppState();
}

class _ListaPreciosAppState extends State<ListaPreciosApp> {
  List<Producto> _lista = [];
  int _totalCount = 0;
  bool _cargando = false;
  bool _hayMas = true;
  int _offset = 0;
  static const int _pageSize = 60;

  final TextEditingController _searchController = TextEditingController();
  String _queryActual = '';
  Timer? _debounce;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _cargarPagina(reset: true);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Paginación: carga más al llegar al final
  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        _hayMas &&
        !_cargando) {
      _cargarPagina();
    }
  }

  Future<void> _cargarPagina({bool reset = false}) async {
    if (_cargando) return;
    setState(() => _cargando = true);

    if (reset) {
      _offset = 0;
      _hayMas = true;
    }

    final query = _queryActual;
    final List<Producto> nuevos;

    if (query.isEmpty) {
      nuevos = await DatabaseService.listar(limit: _pageSize, offset: _offset);
    } else {
      nuevos = await DatabaseService.buscar(query,
          limit: _pageSize, offset: _offset);
    }

    final total = await DatabaseService.contar(
        query: query.isEmpty ? null : query);

    setState(() {
      if (reset) {
        _lista = nuevos;
      } else {
        _lista = [..._lista, ...nuevos];
      }
      _totalCount = total;
      _offset += nuevos.length;
      _hayMas = nuevos.length == _pageSize;
      _cargando = false;
    });
  }

  // Debounce: espera 250 ms después del último keypress
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      setState(() => _queryActual = value.trim());
      _cargarPagina(reset: true);
    });
  }

  Future<void> _importarArchivo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'csv'],
    );
    if (result == null) return;

    final path = result.files.single.path!;
    final ext = result.files.single.extension ?? '';

    // Mostrar progress dialog
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Procesando archivo...'),
          ],
        ),
      ),
    );

    try {
      // Parseo en isolate (no bloquea UI)
      final productos =
          await compute(_parsearArchivo, _ParseArgs(path, ext));

      // Reemplazar toda la tabla
      await DatabaseService.eliminarTodos();
      await DatabaseService.insertarLote(productos);

      if (mounted) {
        Navigator.of(context).pop(); // Cerrar dialog
        _searchController.clear();
        setState(() => _queryActual = '');
        await _cargarPagina(reset: true);
        _notificar('${productos.length} productos importados');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _notificar('Error al procesar el archivo');
      }
    }
  }

  Future<void> _compartirExcel() async {
    if (_totalCount == 0) {
      _notificar('No hay productos para exportar');
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Generando Excel...'),
          ],
        ),
      ),
    );

    try {
      final todos = await DatabaseService.todos();
      final excel = Excel.createExcel();
      final sheet = excel['Precios El Torreón'];

      sheet.appendRow([
        TextCellValue('CODIGO interno'),
        TextCellValue('Codigo de barras'),
        TextCellValue('DESCRIPCION'),
        TextCellValue('MARCA'),
        TextCellValue('PRECIO MAYORISTA (\$)'),
        TextCellValue('PRECIO MINORISTA (\$)'),
        TextCellValue('PROVEEDOR'),
      ]);

      for (final p in todos) {
        sheet.appendRow([
          TextCellValue(p.codigo),
          TextCellValue(p.barra),
          TextCellValue(p.desc),
          TextCellValue(p.marca),
          TextCellValue(p.mayor),
          TextCellValue(p.minor),
          TextCellValue(p.prov),
        ]);
      }

      final bytes = excel.save()!;
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/Lista_Precios_Torreon.xlsx');
      await file.writeAsBytes(bytes);

      if (mounted) {
        Navigator.of(context).pop();
        await Share.shareXFiles(
            [XFile(file.path)], text: 'Lista de Precios El Torreón');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _notificar('Error al generar el archivo');
      }
    }
  }

  Future<void> _eliminarProducto(Producto producto) async {
    // Confirmar antes de borrar
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar producto'),
        content: Text('¿Eliminás "${producto.desc}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmar == true && producto.id != null) {
      await DatabaseService.eliminar(producto.id!);
      await _cargarPagina(reset: true);
    }
  }

  void _notificar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _abrirFormulario({Producto? existente}) {
    final esNuevo = existente == null;
    final controllers = {
      'BARRA': TextEditingController(text: existente?.barra ?? ''),
      'DESC': TextEditingController(text: existente?.desc ?? ''),
      'MARCA': TextEditingController(text: existente?.marca ?? ''),
      'MAYOR': TextEditingController(text: existente?.mayor ?? ''),
      'MINOR': TextEditingController(text: existente?.minor ?? ''),
      'PROV': TextEditingController(text: existente?.prov ?? ''),
    };
    final nodes = List.generate(6, (_) => FocusNode());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(esNuevo ? 'Nuevo producto' : 'Editar producto'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _campo(controllers['BARRA']!, nodes[0], nodes[1],
                  'Código de barras'),
              _campo(controllers['DESC']!, nodes[1], nodes[2], 'Descripción'),
              _campo(controllers['MARCA']!, nodes[2], nodes[3], 'Marca'),
              _campo(controllers['MAYOR']!, nodes[3], nodes[4],
                  'Precio mayorista',
                  isNum: true),
              _campo(controllers['MINOR']!, nodes[4], nodes[5],
                  'Precio minorista',
                  isNum: true),
              _campo(controllers['PROV']!, nodes[5], null, 'Proveedor'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _liberarFormulario(controllers, nodes);
              Navigator.pop(ctx);
            },
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              // Validar precios
              final mayorStr = controllers['MAYOR']!.text
                  .replaceAll(',', '.');
              final minorStr = controllers['MINOR']!.text
                  .replaceAll(',', '.');
              if (double.tryParse(mayorStr) == null ||
                  double.tryParse(minorStr) == null) {
                _notificar('Los precios deben ser números válidos');
                return;
              }

              final producto = Producto(
                id: existente?.id,
                codigo: existente?.codigo ?? '',
                barra: controllers['BARRA']!.text.trim(),
                desc: controllers['DESC']!.text.trim(),
                marca: controllers['MARCA']!.text.trim(),
                mayor: controllers['MAYOR']!.text.trim(),
                minor: controllers['MINOR']!.text.trim(),
                prov: controllers['PROV']!.text.trim(),
              );

              if (esNuevo) {
                await DatabaseService.insertar(producto);
              } else {
                await DatabaseService.actualizar(producto);
              }

              _liberarFormulario(controllers, nodes);
              if (mounted) Navigator.pop(ctx);
              await _cargarPagina(reset: true);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  void _liberarFormulario(
      Map<String, TextEditingController> controllers,
      List<FocusNode> nodes) {
    for (final c in controllers.values) c.dispose();
    for (final n in nodes) n.dispose();
  }

  Widget _campo(
    TextEditingController ctrl,
    FocusNode current,
    FocusNode? next,
    String label, {
    bool isNum = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: ctrl,
        focusNode: current,
        keyboardType: isNum
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        textInputAction:
            next != null ? TextInputAction.next : TextInputAction.done,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        onSubmitted: (_) =>
            next != null ? FocusScope.of(context).requestFocus(next) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitulo = _queryActual.isEmpty
        ? '$_totalCount productos'
        : '${_lista.length} de $_totalCount resultados';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Precios El Torreón',
                style: TextStyle(fontSize: 16)),
            Text(subtitulo,
                style: const TextStyle(
                    fontSize: 11, color: Colors.white70)),
          ],
        ),
        backgroundColor: Colors.blueGrey[900],
        actions: [
          IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Nuevo producto',
              onPressed: () => _abrirFormulario()),
          IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Exportar Excel',
              onPressed: _compartirExcel),
          IconButton(
              icon: const Icon(Icons.upload_file),
              tooltip: 'Importar archivo',
              onPressed: _importarArchivo),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Buscar por descripción o código de barras...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _queryActual.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(
            child: _lista.isEmpty && !_cargando
                ? const Center(
                    child: Text('Sin resultados',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _lista.length + (_hayMas ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _lista.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(
                              child: CircularProgressIndicator()),
                        );
                      }
                      final p = _lista[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        child: ListTile(
                          title: Text(p.desc,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: Text(
                              '${p.marca}  |  Mayor: \$${p.mayor}  |  Menor: \$${p.minor}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit,
                                    color: Colors.blue),
                                onPressed: () =>
                                    _abrirFormulario(existente: p),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete,
                                    color: Colors.red),
                                onPressed: () => _eliminarProducto(p),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.blueGrey[900],
        tooltip: 'Escanear código',
        child:
            const Icon(Icons.qr_code_scanner, color: Colors.white),
        onPressed: () async {
          final result = await Navigator.push<String>(
            context,
            MaterialPageRoute(
                builder: (_) => const EscanerPage()),
          );
          if (result != null && mounted) {
            _searchController.text = result;
            _onSearchChanged(result);
          }
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
// PÁGINA DE ESCÁNER
// ─────────────────────────────────────────────

class EscanerPage extends StatelessWidget {
  const EscanerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear código'),
        backgroundColor: Colors.blueGrey[900],
      ),
      body: MobileScanner(
        onDetect: (capture) {
          final barcodes = capture.barcodes;
          if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
            Navigator.pop(context, barcodes.first.rawValue);
          }
        },
      ),
    );
  }
}