import Foundation

/// Works out which packages a generated Python script needs.
///
/// The scan runs inside the run's own environment, so "missing" means exactly
/// "this environment cannot import it": the standard library and anything
/// already installed are found, and a module that sits beside the script is
/// found because the script's directory is put on the path first. It parses
/// the script with `ast` and never executes it.
enum PythonImportScan {
    struct Result: Decodable, Equatable {
        /// PyPI distribution names to install.
        let install: [String]
        /// Imports pip cannot provide.
        let unavailable: [String]
    }

    /// A distribution name as PyPI spells one. Anything else — a leading
    /// dash that pip would read as an option, a path, a URL — is dropped.
    static func isSafePackageName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil
    }

    /// Prints one JSON line: `{"install": [...], "unavailable": [...]}`.
    /// Imports inside a `try` that handles `ImportError` are the script's own
    /// optional fallbacks and are left alone.
    static let source = #"""
import ast, importlib.util, json, os, sys

# Import names whose PyPI distribution is spelled differently.
PACKAGES = {
    "PIL": "pillow", "cv2": "opencv-python", "sklearn": "scikit-learn",
    "skimage": "scikit-image", "yaml": "pyyaml", "bs4": "beautifulsoup4",
    "dateutil": "python-dateutil", "dotenv": "python-dotenv",
    "Crypto": "pycryptodome", "serial": "pyserial", "usb": "pyusb",
    "attr": "attrs", "jwt": "PyJWT", "OpenSSL": "pyOpenSSL",
    "magic": "python-magic", "docx": "python-docx", "pptx": "python-pptx",
    "fitz": "PyMuPDF", "wx": "wxPython", "Levenshtein": "python-Levenshtein",
    "telegram": "python-telegram-bot", "discord": "discord.py",
    "googleapiclient": "google-api-python-client", "Bio": "biopython",
    "pygame": "pygame", "mpl_toolkits": "matplotlib", "lxml": "lxml",
    "win32api": None, "win32con": None, "winreg": None, "msvcrt": None,
    "tkinter": None, "_tkinter": None, "turtle": None, "gi": None,
}

path = sys.argv[1]
with open(path, "rb") as handle:
    tree = ast.parse(handle.read(), filename=path)
sys.path.insert(0, os.path.dirname(os.path.abspath(path)))

def catches_import_error(node):
    for handler in node.handlers:
        kind = handler.type
        names = kind.elts if isinstance(kind, ast.Tuple) else [kind]
        for name in names:
            if name is None:
                return True
            if isinstance(name, ast.Name) and name.id in (
                    "ImportError", "ModuleNotFoundError", "Exception", "BaseException"):
                return True
    return False

found = []
def visit(node, optional):
    if isinstance(node, ast.Try) and catches_import_error(node):
        for child in node.body:
            visit(child, True)
        for child in node.handlers + node.orelse + node.finalbody:
            visit(child, optional)
        return
    if not optional:
        if isinstance(node, ast.Import):
            found.extend(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            found.append(node.module.split(".")[0])
    for child in ast.iter_child_nodes(node):
        visit(child, optional)
visit(tree, False)

install, unavailable = [], []
for name in dict.fromkeys(found):
    if name == "__future__":
        continue
    try:
        if importlib.util.find_spec(name) is not None:
            continue
    except (ImportError, ValueError):
        pass
    package = PACKAGES.get(name, name)
    if package is None:
        unavailable.append(name)
    elif package not in install:
        install.append(package)
print(json.dumps({"install": install, "unavailable": unavailable}))
"""#
}
