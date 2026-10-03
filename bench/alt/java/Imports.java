// javac's own parser through the JDK compiler API: parse only, no symbol
// entry or attribution; import declarations counted from the syntax tree.
// Same output rows as bench/ops.
import com.sun.source.tree.CompilationUnitTree;
import com.sun.source.util.JavacTask;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import javax.tools.JavaCompiler;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;

public class Imports {
    public static void main(String[] args) throws Exception {
        if (args.length != 2 || !args[0].equals("imports/java")) throw new IllegalArgumentException("usage: Imports imports/java <file>");
        Path file = Path.of(args[1]);
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        StandardJavaFileManager files = compiler.getStandardFileManager(null, null, null);
        var units = files.getJavaFileObjects(file);
        java.util.function.IntSupplier op = () -> {
            try {
                JavacTask task = (JavacTask) compiler.getTask(null, files, null, List.of("-proc:none"), null, units);
                int count = 0;
                for (CompilationUnitTree unit : task.parse()) count += unit.getImports().size();
                return count;
            } catch (java.io.IOException error) {
                throw new RuntimeException(error);
            }
        };
        int count = op.getAsInt();
        String prefix = "javac\timports/java\t";
        if (System.getenv("BENCH_SMOKE") != null) {
            System.out.println(prefix + "ns_per_op\t0\tns");
        } else {
            long iterations = 0, start = System.nanoTime();
            while (iterations < 3 || System.nanoTime() - start < 200_000_000L) { count = op.getAsInt(); iterations++; }
            System.out.printf("%sns_per_op\t%.3f\tns%n", prefix, (System.nanoTime() - start) / (double) iterations);
            System.out.println(prefix + "iterations\t" + iterations + "\titerations");
        }
        System.out.println(prefix + "source\t" + Files.size(file) + "\tbytes");
        System.out.println(prefix + "imports\t" + count + "\tcount");
    }
}
