package matvis;

/** Callback interface — fired whenever controller state changes. */
@FunctionalInterface
public interface MatVisListener {
    void onUpdate();
}
