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
      where: 'desc LIKE ? OR barra LIKE ?',
      whereArgs: [q, q],
      orderBy: 'desc COLLATE NOCASE',
      limit: limit,
      offset: offset,
    );
    return rows.map(Producto.fromMap).toList();
  }

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

  // Busca por código de barras exacto
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
    final rows =
        await database.query('productos', orderBy: 'desc COLLATE NOCASE');
    return rows.map(Producto.fromMap).toList();
  }
}

// ─────────────────────────────────────────────
// PARSEO EN ISOLATE
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

// ─────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────

const _kRojo = Color(0xFFB71C1C);

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

  // Solo actualiza el contador al iniciar — la lista queda vacía
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
    // Sin query → pantalla en blanco
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
    final nuevos = await DatabaseService.buscar(query,
        limit: _pageSize, offset: _offset);
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
        // Limpiar lista al borrar búsqueda
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

  // Escáner desde la barra de búsqueda:
  // si el código existe → buscar, si no → abrir formulario
  Future<void> _escanearEnBusqueda() async {
    final codigo = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const EscanerPage()),
    );
    if (codigo == null || !mounted) return;

    final existente = await DatabaseService.buscarPorBarra(codigo);
    if (!mounted) return;

    if (existente != null) {
      _searchController.text = codigo;
      setState(() => _queryActual = codigo);
      _cargarPagina(reset: true);
    } else {
      _abrirFormulario(barraPrecargada: codigo);
    }
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
      final productos =
          await compute(_parsearArchivo, _ParseArgs(path, ext));

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

      // Template xlsx con una sola hoja 'Precios El Torreón' — evita Sheet1 en blanco
      const templateB64 =
          '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';

      final templateBytes = base64Decode(templateB64);
      final excel = Excel.decodeBytes(templateBytes);
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
      await _actualizarContador();
    }
  }

  void _notificar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _abrirFormulario({Producto? existente, String? barraPrecargada}) {
    final esNuevo = existente == null;
    final controllers = {
      'BARRA': TextEditingController(
          text: barraPrecargada ?? existente?.barra ?? ''),
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
              // Código de barras con botón escáner integrado
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
              final mayorStr =
                  controllers['MAYOR']!.text.replaceAll(',', '.');
              final minorStr =
                  controllers['MINOR']!.text.replaceAll(',', '.');
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
              await _actualizarContador();
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
                      labelText: 'Buscar por descripción o código...',
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
                              child: Center(
                                  child: CircularProgressIndicator()),
                            );
                          }
                          final p = _lista[index];
                          final isSelected = _selectedId == p.id;
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            color: isSelected ? Colors.red[50] : null,
                            child: ListTile(
                              onTap: () {
                                setState(() {
                                  _selectedId =
                                      isSelected ? null : p.id;
                                });
                              },
                              title: Text(
                                p.desc,
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
                                    '\$${p.minor}',
                                    style: const TextStyle(
                                      color: Colors.red,
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'Mayor: \$${p.mayor}  |  ${p.marca}',
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
                                              _abrirFormulario(existente: p),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete,
                                              color: Colors.red),
                                          onPressed: () =>
                                              _eliminarProducto(p),
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

// ─────────────────────────────────────────────
// PÁGINA DE ESCÁNER
// ─────────────────────────────────────────────

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