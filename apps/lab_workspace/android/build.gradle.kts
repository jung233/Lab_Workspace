allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Resolve this path before changing buildDirectory; keeping a Provider derived
// from the same DirectoryProperty here makes Gradle evaluate it recursively.
val relocatedBuild = rootProject.layout.buildDirectory.dir("../../build/android").get()
rootProject.layout.buildDirectory.set(relocatedBuild)
subprojects {
    project.layout.buildDirectory.set(relocatedBuild.dir(project.name))
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
