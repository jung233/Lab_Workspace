// Apply from app/build.gradle.kts after the com.chaquo.python plugin is applied.
// The dynamic builder keeps this isolated script independent of generated
// Kotlin DSL accessors while still configuring Chaquopy's documented DSL.
import org.gradle.kotlin.dsl.withGroovyBuilder

plugins.withId("com.chaquo.python") {
    extensions.getByName("chaquopy").withGroovyBuilder {
        "defaultConfig" {
            "version"("3.15")
        }
        "sourceSets" {
            "getByName"("main") {
                "srcDir"(file("../../../../python"))
            }
        }
    }
}\n
