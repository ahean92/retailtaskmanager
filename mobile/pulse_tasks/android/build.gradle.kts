allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Своя камера для серийной съёмки (#36914) приходит пакетом camera, а его андроидная
// половина — camera_android_camerax 0.6.30 поверх androidx camera-core 1.5.x. Под AGP 9
// она не компилируется: javac спотыкается о type-аннотации @NonNull в camera-core,
// потому что класс androidx.concurrent.futures.CallbackToFutureAdapter, на который они
// ссылаются, в компиляционном classpath модуля не оказывается («Cannot attach type
// annotations ... class file for ... CallbackToFutureAdapter not found»). Дописываем
// зависимость ему сами — только на компиляцию и только этому модулю: в рантайме она
// приезжает транзитивно, менять реализацию камеры или откатывать версию ради этого
// незачем. Строка уйдёт, когда плагин починит объявление у себя.
subprojects {
    if (name == "camera_android_camerax") {
        plugins.withId("com.android.library") {
            dependencies.add("compileOnly", "androidx.concurrent:concurrent-futures:1.2.0")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
