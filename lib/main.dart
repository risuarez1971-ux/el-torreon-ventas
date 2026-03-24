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
        await db.execute('CREATE INDEX idx_desc  ON productos(desc  COLLATE NOCASE)');
        await db.execute('CREATE INDEX idx_barra ON productos(barra)');
      },
    );
  }

  static Future<List<Producto>> buscar(String query,
      {int limit = 60, int offset = 0}) async {
    final database = await db;
    final q = '%$query%';
    final rows = await database.query(
      'productos',
      where: 'desc LIKE ? OR barra LIKE ? OR codigo LIKE ? OR marca LIKE ?',
      whereArgs: [q, q, q, q],
      orderBy: 'desc COLLATE NOCASE',
      limit: limit,
      offset: offset,
    );
    return rows.map(Producto.fromMap).toList();
  }

  static Future<List<Producto>> listar({int limit = 60, int offset = 0}) async {
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
      final result = await database.rawQuery('SELECT COUNT(*) as c FROM productos');
      return result.first['c'] as int;
    }
    final q = '%$query%';
    final result = await database.rawQuery(
      'SELECT COUNT(*) as c FROM productos WHERE desc LIKE ? OR barra LIKE ? OR codigo LIKE ? OR marca LIKE ?',
      [q, q, q, q],
    );
    return result.first['c'] as int;
  }

  static Future<Producto?> buscarPorBarra(String barra) async {
    final database = await db;
    final rows = await database.query(
      'productos',
      where: 'barra = ?',
      whereArgs: [barra],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Producto.fromMap(rows.first);
  }

  static Future<String> proximoCodigo() async {
    final database = await db;
    final result = await database.rawQuery(
      "SELECT MAX(CAST(codigo AS INTEGER)) as max_cod FROM productos WHERE codigo != '' AND codigo GLOB '[0-9]*'",
    );
    final maxCod = result.first['max_cod'];
    if (maxCod == null) return '1';
    return ((maxCod as int) + 1).toString();
  }

  static Future<void> insertar(Producto producto) async {
    final database = await db;
    await database.insert('productos', producto.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

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
    final rows = await database.query('productos', orderBy: 'desc COLLATE NOCASE');
    return rows.map(Producto.fromMap).toList();
  }
}

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
      break;
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

const _kRojo = Color(0xFFB71C1C);

void main() {
  runApp(const MaterialApp(
    home: ListaPreciosApp(),
    debugShowCheckedModeBanner: false,
  ));
}

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
  int? _selectedId;

  final TextEditingController _searchController = TextEditingController();
  String _queryActual = '';
  Timer? _debounce;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _actualizarContador();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _actualizarContador() async {
    final total = await DatabaseService.contar();
    if (mounted) setState(() => _totalCount = total);
  }

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
    if (_queryActual.isEmpty) {
      setState(() {
        _lista = [];
        _cargando = false;
        _selectedId = null;
      });
      return;
    }

    setState(() => _cargando = true);

    if (reset) {
      _offset = 0;
      _hayMas = true;
      _selectedId = null;
    }

    final query = _queryActual;
    final nuevos = await DatabaseService.buscar(query, limit: _pageSize, offset: _offset);
    final total = await DatabaseService.contar(query: query);

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

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      final trimmed = value.trim();
      setState(() => _queryActual = trimmed);
      if (trimmed.isEmpty) {
        setState(() {
          _lista = [];
          _selectedId = null;
          _hayMas = false;
        });
        _actualizarContador();
      } else {
        _cargarPagina(reset: true);
      }
    });
  }

  Future<void> _escanearEnBusqueda() async {
  final codigo = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const EscanerPage()),
  );
  if (codigo == null || !mounted) return;

  final existente = await DatabaseService.buscarPorBarra(codigo);
  if (!mounted) return;

  if (existente != null) {
    // Mostrar en la lista, no abrir diálogo de precios
    _searchController.text = codigo;
    setState(() => _queryActual = codigo);
    _cargarPagina(reset: true);
  } else {
    _abrirFormulario(barraPrecargada: codigo);
  }
}

  void _abrirActualizacionPrecio(Producto producto) {
    final mayorCtrl = TextEditingController(text: producto.mayor);
    final minorCtrl = TextEditingController(text: producto.minor);
    final porcentajeCtrl = TextEditingController();
    bool usarPorcentaje = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(producto.desc,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              Text(producto.marca,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setStateDialog(() => usarPorcentaje = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: !usarPorcentaje ? _kRojo : Colors.grey[200],
                            borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(8)),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Precio directo',
                            style: TextStyle(
                              color: !usarPorcentaje ? Colors.white : Colors.black54,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setStateDialog(() => usarPorcentaje = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: usarPorcentaje ? _kRojo : Colors.grey[200],
                            borderRadius: const BorderRadius.horizontal(
                                right: Radius.circular(8)),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Porcentaje',
                            style: TextStyle(
                              color: usarPorcentaje ? Colors.white : Colors.black54,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(children: [
                        const Text('Mayor actual',
                            style: TextStyle(fontSize: 11, color: Colors.grey)),
                        Text('\$${producto.mayor}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ]),
                      Column(children: [
                        const Text('Menor actual',
                            style: TextStyle(fontSize: 11, color: Colors.grey)),
                        Text('\$${producto.minor}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, color: Colors.red)),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (!usarPorcentaje) ...[
                  TextField(
                    controller: mayorCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Precio mayorista nuevo',
                      border: OutlineInputBorder(),
                      prefixText: '\$ ',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: minorCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Precio minorista nuevo',
                      border: OutlineInputBorder(),
                      prefixText: '\$ ',
                    ),
                  ),
                ] else ...[
                  TextField(
                    controller: porcentajeCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Porcentaje de aumento',
                      border: OutlineInputBorder(),
                      suffixText: '%',
                      hintText: 'Ej: 15',
                    ),
                    onChanged: (val) {
                      final pct = double.tryParse(val.replaceAll(',', '.'));
                      if (pct != null) {
                        final mayorNum = double.tryParse(
                            producto.mayor.replaceAll(',', '.'));
                        final minorNum = double.tryParse(
                            producto.minor.replaceAll(',', '.'));
                        if (mayorNum != null) {
                          mayorCtrl.text = (mayorNum * (1 + pct / 100))
                              .toStringAsFixed(2)
                              .replaceAll('.', ',');
                        }
                        if (minorNum != null) {
                          minorCtrl.text = (minorNum * (1 + pct / 100))
                              .toStringAsFixed(2)
                              .replaceAll('.', ',');
                        }
                        setStateDialog(() {});
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  if (mayorCtrl.text != producto.mayor || minorCtrl.text != producto.minor)
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          Column(children: [
                            const Text('Mayor nuevo',
                                style: TextStyle(fontSize: 11, color: Colors.grey)),
                            Text('\$${mayorCtrl.text}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green)),
                          ]),
                          Column(children: [
                            const Text('Menor nuevo',
                                style: TextStyle(fontSize: 11, color: Colors.grey)),
                            Text('\$${minorCtrl.text}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green)),
                          ]),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                mayorCtrl.dispose();
                minorCtrl.dispose();
                porcentajeCtrl.dispose();
                Navigator.pop(ctx);
              },
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _kRojo, foregroundColor: Colors.white),
              onPressed: () async {
                final mayorStr = mayorCtrl.text.replaceAll(',', '.');
                final minorStr = minorCtrl.text.replaceAll(',', '.');
                if (double.tryParse(mayorStr) == null ||
                    double.tryParse(minorStr) == null) {
                  _notificar('Los precios deben ser números válidos');
                  return;
                }
                final actualizado = producto.copyWith(
                  mayor: mayorCtrl.text.trim(),
                  minor: minorCtrl.text.trim(),
                );
                await DatabaseService.actualizar(actualizado);
                mayorCtrl.dispose();
                minorCtrl.dispose();
                porcentajeCtrl.dispose();
                if (mounted) Navigator.pop(ctx);
                _notificar('Precio actualizado');
                if (_queryActual.isNotEmpty) _cargarPagina(reset: true);
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importarArchivo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'csv'],
    );
    if (result == null) return;

    final path = result.files.single.path!;
    final ext = result.files.single.extension ?? '';

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
      final productos = await compute(_parsearArchivo, _ParseArgs(path, ext));
      await DatabaseService.eliminarTodos();
      await DatabaseService.insertarLote(productos);

      if (mounted) {
        Navigator.of(context).pop();
        _searchController.clear();
        setState(() {
          _queryActual = '';
          _lista = [];
          _totalCount = productos.length;
          _selectedId = null;
          _offset = 0;
          _hayMas = false;
          _cargando = false;
        });
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
      excel.rename('Sheet1', 'Precios');
      final sheet = excel['Precios'];

      sheet.appendRow([
        TextCellValue('CODIGO INTERNO'),
        TextCellValue('CODIGO DE BARRAS'),
        TextCellValue('DESCRIPCION'),
        TextCellValue('MARCA'),
        TextCellValue('MAYOR'),
        TextCellValue('MINOR'),
        TextCellValue('PROVEEDOR'),
      ]);

      for (final prod in todos) {
        sheet.appendRow([
          TextCellValue(prod.codigo),
          TextCellValue(prod.barra),
          TextCellValue(prod.desc),
          TextCellValue(prod.marca),
          TextCellValue(prod.mayor),
          TextCellValue(prod.minor),
          TextCellValue(prod.prov),
        ]);
      }

      final bytes = excel.save();
      if (bytes == null) throw Exception('bytes null');

      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/Lista_Precios_Torreon.xlsx');
      await file.writeAsBytes(bytes, flush: true);

      if (mounted) {
        Navigator.of(context).pop();
        await SharePlus.instance.share(
            ShareParams(files: [XFile(file.path)], text: 'Lista de precios El Torreon'));
      }
    } catch (e, stack) {
      debugPrint('ERROR EXCEL: $e');
      debugPrint('STACK: $stack');
      if (mounted) {
        Navigator.of(context).pop();
        _notificar('Error al generar el Excel');
      }
    }
  }

  Future<void> _eliminarProducto(Producto producto) async {
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
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmar == true && producto.id != null) {
      await DatabaseService.eliminar(producto.id!);
      await _cargarPagina(reset: true);
      await _actualizarContador();
    }
  }

  void _notificar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _abrirFormulario({Producto? existente, String? barraPrecargada}) {
    final esNuevo = existente == null;
    final controllers = {
      'BARRA': TextEditingController(text: barraPrecargada ?? existente?.barra ?? ''),
      'DESC': TextEditingController(text: existente?.desc ?? ''),
      'MARCA': TextEditingController(text: existente?.marca ?? ''),
      'MAYOR': TextEditingController(text: existente?.mayor ?? ''),
      'MINOR': TextEditingController(text: existente?.minor ?? ''),
      'PROV': TextEditingController(text: existente?.prov ?? ''),
    };
    final nodes = List.generate(6, (_) => FocusNode());

    final Future<String> codigoFuturo = esNuevo
        ? DatabaseService.proximoCodigo()
        : Future.value(existente!.codigo);

    showDialog(
      context: context,
      builder: (ctx) => FutureBuilder<String>(
        future: codigoFuturo,
        builder: (ctx, snapshot) {
          final codigoMostrado = snapshot.data ?? '...';
          return AlertDialog(
            title: Text(esNuevo ? 'Nuevo producto' : 'Editar producto'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: TextField(
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'Código interno',
                        border: const OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.grey[100],
                        prefixIcon: const Icon(Icons.tag),
                      ),
                      controller: TextEditingController(text: codigoMostrado),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controllers['BARRA']!,
                            focusNode: nodes[0],
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Código de barras',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) =>
                                FocusScope.of(ctx).requestFocus(nodes[1]),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Material(
                          color: _kRojo,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () async {
                              final codigo = await Navigator.push<String>(
                                ctx,
                                MaterialPageRoute(
                                    builder: (_) => const EscanerPage()),
                              );
                              if (codigo != null) {
                                controllers['BARRA']!.text = codigo;
                              }
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(12),
                              child: Icon(Icons.qr_code_scanner,
                                  color: Colors.white, size: 24),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _campo(controllers['DESC']!, nodes[1], nodes[2], 'Descripción'),
                  _campo(controllers['MARCA']!, nodes[2], nodes[3], 'Marca'),
                  _campo(controllers['MAYOR']!, nodes[3], nodes[4], 'Precio mayorista',
                      isNum: true),
                  _campo(controllers['MINOR']!, nodes[4], nodes[5], 'Precio minorista',
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
                  final mayorStr = controllers['MAYOR']!.text.replaceAll(',', '.');
                  final minorStr = controllers['MINOR']!.text.replaceAll(',', '.');
                  if (double.tryParse(mayorStr) == null ||
                      double.tryParse(minorStr) == null) {
                    _notificar('Los precios deben ser números válidos');
                    return;
                  }

                  final producto = Producto(
                    id: existente?.id,
                    codigo: esNuevo
                        ? await DatabaseService.proximoCodigo()
                        : existente!.codigo,
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
                  await _actualizarContador();
                },
                child: const Text('Guardar'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _liberarFormulario(
      Map<String, TextEditingController> controllers, List<FocusNode> nodes) {
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
        textInputAction: next != null ? TextInputAction.next : TextInputAction.done,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onSubmitted: (_) =>
            next != null ? FocusScope.of(context).requestFocus(next) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitulo = _queryActual.isEmpty
        ? '$_totalCount productos cargados'
        : '${_lista.length} de $_totalCount resultados';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Precios El Torreón',
                style: TextStyle(fontSize: 16, color: Colors.white)),
            Text(subtitulo,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        backgroundColor: _kRojo,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              tooltip: 'Nuevo producto',
              onPressed: () => _abrirFormulario()),
          IconButton(
              icon: const Icon(Icons.share, color: Colors.white),
              tooltip: 'Exportar Excel',
              onPressed: _compartirExcel),
          IconButton(
              icon: const Icon(Icons.upload_file, color: Colors.white),
              tooltip: 'Importar archivo',
              onPressed: _importarArchivo),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      labelText: 'Buscar por descripción, código, marca...',
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
                const SizedBox(width: 8),
                Material(
                  color: _kRojo,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: _escanearEnBusqueda,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.qr_code_scanner,
                          color: Colors.white, size: 28),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _queryActual.isEmpty && _lista.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search, size: 64, color: Colors.black12),
                        SizedBox(height: 12),
                        Text('Buscá un producto o escaneá un código',
                            style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : _lista.isEmpty && !_cargando
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
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          final prod = _lista[index];
                          final isSelected = _selectedId == prod.id;
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            color: isSelected ? Colors.red[50] : null,
                            child: ListTile(
                              onTap: () {
                                setState(() {
                                  _selectedId = isSelected ? null : prod.id;
                                });
                              },
                              title: Text(
                                prod.desc,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black,
                                  fontSize: 15,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '\$${prod.minor}',
                                    style: const TextStyle(
                                      color: Colors.red,
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'Mayor: \$${prod.mayor}  |  ${prod.marca}',
                                    style: const TextStyle(
                                      color: Colors.black54,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              isThreeLine: true,
                              trailing: isSelected
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit,
                                              color: Colors.blue),
                                          onPressed: () =>
                                              _abrirFormulario(existente: prod),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete,
                                              color: Colors.red),
                                          onPressed: () =>
                                              _eliminarProducto(prod),
                                        ),
                                      ],
                                    )
                                  : null,
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class EscanerPage extends StatefulWidget {
  const EscanerPage({super.key});

  @override
  State<EscanerPage> createState() => _EscanerPageState();
}

class _EscanerPageState extends State<EscanerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _detectado = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear código'),
        backgroundColor: _kRojo,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) async {
          if (_detectado) return;
          final barcodes = capture.barcodes;
          if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
            _detectado = true;
            await _controller.stop();
            if (mounted) {
              Navigator.pop(context, barcodes.first.rawValue);
            }
          }
        },
      ),
    );
  }
}