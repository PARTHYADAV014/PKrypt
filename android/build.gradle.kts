import org.gradle.api.tasks.compile.JavaCompile
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("org.jetbrains.kotlin.android") apply false
}

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
    if (project.name != "app") {
        project.afterEvaluate {
            tasks.withType<KotlinCompile>().configureEach {
                val javaTaskName = name.replace("Kotlin", "JavaWithJavac")
                val javaTask = tasks.findByName(javaTaskName) as? JavaCompile
                val rawTarget = javaTask?.targetCompatibility
                val normalized = when (rawTarget) {
                    "8" -> "1.8"
                    null, "" -> "11"
                    else -> rawTarget
                }
                val resolvedTarget = try {
                    JvmTarget.fromTarget(normalized)
                } catch (_: IllegalArgumentException) {
                    JvmTarget.JVM_11
                }
                compilerOptions.jvmTarget.set(resolvedTarget)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}