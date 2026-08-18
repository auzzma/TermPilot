@testable import TermPilotApp
import XCTest

final class DockerManagementTests: XCTestCase {
    func testDockerCommandsValidateIdentifiersAndQuoteUserInput() throws {
        XCTAssertEqual(
            DockerManagement.containerCommand(
                id: "abc123",
                action: .remove
            ),
            "docker rm -f abc123"
        )
        XCTAssertEqual(
            DockerManagement.containerCommand(
                id: "abc123",
                action: .rename,
                newName: "api; rm"
            ),
            "docker rename abc123 'apirm'"
        )
        XCTAssertEqual(
            DockerManagement.imageTagCommand(
                id: "sha256:abc123",
                repository: "team/api",
                tag: "stable"
            ),
            "docker tag abc123 'team/api:stable'"
        )
        XCTAssertNil(
            DockerManagement.imageTagCommand(
                id: "abc123",
                repository: "",
                tag: "latest"
            )
        )
        let shell = try XCTUnwrap(
            DockerManagement.interactiveShellCommand(
                containerID: "abc123"
            )
        )
        XCTAssertTrue(shell.contains("docker exec -it abc123"))
        XCTAssertFalse(shell.contains("sudo"))
        XCTAssertFalse(shell.contains("su -"))
        let suShell = try XCTUnwrap(
            DockerManagement.interactiveShellCommand(
                containerID: "abc123",
                elevationMethod: .su
            )
        )
        XCTAssertTrue(suShell.hasPrefix("su - root -c "))
        XCTAssertFalse(suShell.contains("sudo"))
        let logs = try XCTUnwrap(
            DockerManagement.logsCommand(
                containerID: "abc123",
                elevationMethod: .sudo
            )
        )
        XCTAssertTrue(logs.contains("logs -f --tail 200 abc123"))
        XCTAssertTrue(logs.hasPrefix("sudo -H -S -k "))
        XCTAssertFalse(logs.contains("su -"))
    }

    func testDockerContainerInspectParsesStructuredDetails() throws {
        let output = """
        [{
          "Id": "0123456789abcdef",
          "Created": "2026-08-02T00:00:00Z",
          "Path": "/bin/server",
          "Args": ["--port", "8080"],
          "State": {
            "Status": "running",
            "StartedAt": "2026-08-02T00:01:00Z"
          },
          "Config": {
            "Image": "team/api:latest",
            "Env": ["A=1"],
            "Labels": {"app": "api"}
          },
          "HostConfig": {
            "RestartPolicy": {"Name": "unless-stopped"}
          },
          "NetworkSettings": {
            "Ports": {
              "8080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "18080"}]
            },
            "Networks": {"bridge": {}}
          },
          "Mounts": [{
            "Source": "/data",
            "Destination": "/srv/data"
          }]
        }]
        """

        let details = try XCTUnwrap(
            DockerManagement.parseInspect(output, kind: .container)
        )

        XCTAssertEqual(
            details.fields.first { $0.label == "ID" }?.value,
            "0123456789ab"
        )
        XCTAssertEqual(
            details.fields.first { $0.label == "Command" }?.value,
            "/bin/server --port 8080"
        )
        XCTAssertEqual(
            details.lists.first { $0.label == "Ports" }?.values,
            ["8080/tcp -> 127.0.0.1:18080"]
        )
        XCTAssertEqual(
            details.lists.first { $0.label == "Mounts" }?.values,
            ["/data -> /srv/data"]
        )
    }

    func testDockerImageInspectParsesTagsAndPlatform() throws {
        let output = """
        [{
          "Id": "sha256:abcdef1234567890",
          "RepoTags": ["team/api:latest"],
          "RepoDigests": ["team/api@sha256:1234"],
          "Created": "2026-08-02T00:00:00Z",
          "Size": 54321000,
          "Architecture": "arm64",
          "Os": "linux",
          "Config": {
            "Entrypoint": ["/entrypoint"],
            "Cmd": ["serve"],
            "WorkingDir": "/app",
            "ExposedPorts": {"8080/tcp": {}},
            "Env": ["PATH=/usr/bin"]
          }
        }]
        """

        let details = try XCTUnwrap(
            DockerManagement.parseInspect(output, kind: .image)
        )

        XCTAssertEqual(
            details.fields.first { $0.label == "Platform" }?.value,
            "linux/arm64"
        )
        XCTAssertEqual(
            details.fields.first { $0.label == "Working Directory" }?.value,
            "/app"
        )
        XCTAssertEqual(
            details.lists.first { $0.label == "Tags" }?.values,
            ["team/api:latest"]
        )
        XCTAssertEqual(
            details.lists.first { $0.label == "Exposed Ports" }?.values,
            ["8080/tcp"]
        )
    }
}
