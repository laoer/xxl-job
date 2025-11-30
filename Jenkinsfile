pipeline {
    agent any

    environment {
        // Docker 镜像名称
        IMAGE_NAME = 'xxl-job-admin'
        // Docker 镜像标签，这里使用 Jenkins 的构建号
        IMAGE_TAG = "${env.BUILD_NUMBER}"
        // Dockerfile 的路径
        DOCKERFILE_PATH = 'xxl-job-admin/Dockerfile'
		MAVEN_SETTINGS_CREDENTIAL_ID = 'maven-settings' // Maven settings.xml 文件凭据ID
    }

    stages {
        stage('Checkout') {
            steps {
                // 从 Jenkins 配置的 SCM (Source Code Management) 检出代码
                echo 'Checking out source code...'
                checkout scm
            }
        }

		stage('Prepare Maven Settings') {
			steps {
				echo "Fetching custom Maven settings.xml..."
				sh "chmod -R 755 ${env.WORKSPACE}"
				withCredentials([file(credentialsId: MAVEN_SETTINGS_CREDENTIAL_ID, variable: 'MAVEN_SETTINGS_FILE')]) {
					sh "cp ${env.MAVEN_SETTINGS_FILE} ./settings.xml"
					echo "Custom settings.xml copied to workspace root."
				}
			}
		}

        stage('Build Docker Image') {
            steps {
                script {
                    echo "Starting Docker image build for ${IMAGE_NAME}:${IMAGE_TAG} on platform linux/arm64..."
                    
                    // 使用 sh 步骤直接执行 docker buildx 命令，并指定 platform
                    // --load 参数确保构建的镜像加载到本地 Docker deamon，以便后续步骤可以使用
                    sh "docker buildx build --platform linux/arm64 --tag ${IMAGE_NAME}:${IMAGE_TAG} --file ${DOCKERFILE_PATH} . --load"

                    echo "Docker image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"

                    // (可选) 推送镜像到 Docker Registry
                    // 因为镜像是通过 sh 命令构建的，需要通过 docker.image() 获取它的句柄
                    def customImage = docker.image("${IMAGE_NAME}:${IMAGE_TAG}")

                    /*
                    docker.withRegistry('https://your.registry.com', 'your-registry-credentials-id') {
                        echo "Pushing image ${IMAGE_NAME}:${IMAGE_TAG}..."
                        customImage.push()
                        echo "Image pushed successfully."
                    }
                    */

					def saveDir = "/opt/output_images"
					def tarFileName = "${saveDir}/${IMAGE_NAME}-arm64-latest.tar"
					sh "docker save -o ${tarFileName} ${IMAGE_NAME}-arm64:latest"
                }
            }
        }

        stage('Cleanup') {
            steps {
                // 清理构建过程中产生的悬空镜像（dangling images）
                echo "Cleaning up dangling Docker images..."
                sh 'docker rmi $(docker images -f "dangling=true" -q) || true'
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution finished.'
        }
        success {
            echo 'Pipeline completed successfully!'
        }
        failure {
            echo 'Pipeline failed. Please check the logs.'
        }
    }
}
