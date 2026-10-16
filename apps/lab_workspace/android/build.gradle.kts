allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val relocatedBuild = rootProject.layout.buildDirectory.dir("../../build/android")
rootProject.layout.buildDirectory.value(relocatedBuild)
subprojects {
    project.layout.buildDirectory.value(relocatedBuild.map { it.dir(project.name) })
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
